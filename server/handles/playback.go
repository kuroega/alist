package handles

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/alist-org/alist/v3/internal/conf"
	"github.com/alist-org/alist/v3/internal/model"
	"github.com/alist-org/alist/v3/internal/playback"
	"github.com/alist-org/alist/v3/internal/sign"
	"github.com/alist-org/alist/v3/server/common"
	"github.com/gin-gonic/gin"
)

var playbackManager *playback.Manager
var playbackTransfers chan struct{}

// InitPlayback is called before the router starts accepting requests.
func InitPlayback() {
	ClosePlayback()
	if !conf.Conf.Playback.Enabled {
		return
	}
	cfg := conf.Conf.Playback
	port := conf.Conf.Scheme.HttpPort
	internalPlayback := url.URL{
		Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		Path: strings.TrimSuffix(conf.URL.Path, "/") + "/playback",
	}
	// Bound response-held buffers too: a slow client can retain an evicted
	// segment until its HTTP transfer finishes.
	playbackTransfers = make(chan struct{}, max(1, cfg.MaxSessions))
	playbackManager = playback.NewManager(playback.Config{
		FFmpeg: cfg.FFmpeg, MaxSessions: cfg.MaxSessions, MaxConcurrent: cfg.MaxConcurrent,
		MaxCacheBytes:  int64(cfg.MaxCacheMB) * 1024 * 1024,
		IdleTimeout:    time.Duration(cfg.IdleMinutes) * time.Minute,
		SourceCacheDir: cfg.SourceCacheDir, MaxSourceCacheBytes: int64(cfg.SourceCacheMaxMB) * 1024 * 1024,
		SourceChunkBytes: int64(cfg.SourceChunkMB) * 1024 * 1024, SourceBaseURL: internalPlayback.String(),
	})
}

// ClosePlayback cancels encoders before the HTTP server is shut down.
func ClosePlayback() {
	if playbackManager != nil {
		playbackManager.Close()
	}
}

// compatiblePlaybackURL is called only after FsGet has checked the user's
// path, roles and folder password. The opaque URL delegates that read access
// to the media player until the session expires; it grants no browse access.
func compatiblePlaybackURL(c *gin.Context, user *model.User, rawPath string, obj model.Obj) (string, error) {
	if playbackManager == nil || !conf.Conf.Playback.Enabled || !strings.EqualFold(path.Ext(obj.GetName()), ".mkv") {
		return "", nil
	}
	port := conf.Conf.Scheme.HttpPort
	if port <= 0 || conf.Conf.Scheme.ForceHttps {
		return "", errors.New("compatible playback requires the local HTTP listener without forced HTTPS")
	}
	// Never derive this URL from Host or forwarded headers. The /p route retains
	// all existing signature and storage proxy checks and refreshes cloud links.
	source := url.URL{
		Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		Path: strings.TrimSuffix(conf.URL.Path, "/") + "/p" + rawPath,
	}
	query := url.Values{
		"sign": {sign.NotExpired(rawPath)}, "d": {"1"}, "internal_playback": {"1"},
	}
	source.RawQuery = query.Encode()
	key := fmt.Sprintf("%d\x00%s\x00%d:%d", user.ID, rawPath, obj.GetSize(), obj.ModTime().UnixNano())
	session, err := playbackManager.Open(c.Request.Context(), key, source.String(), obj.GetSize())
	if errors.Is(err, playback.ErrNotNeeded) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return common.GetApiUrl(c.Request) + "/playback/" + session.ID + "/index.m3u8", nil
}

// Playback serves only capabilities created by the authenticated FsGet path.
// Filenames are parsed, never joined to filesystem paths, and callers cannot
// supply an upstream URL or encoder arguments.
func Playback(c *gin.Context) {
	c.Set("private_playback", true)
	c.Header("Cache-Control", "private, no-store")
	c.Header("Referrer-Policy", "no-referrer")
	c.Header("X-Content-Type-Options", "nosniff")
	if playbackManager == nil || !conf.Conf.Playback.Enabled {
		c.Status(http.StatusNotFound)
		return
	}
	id, resource := c.Param("id"), c.Param("resource")
	if resource == "source" {
		host, _, _ := net.SplitHostPort(c.Request.RemoteAddr)
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			c.Status(http.StatusNotFound)
			return
		}
		if err := playbackManager.Source(c.Writer, c.Request, id); err != nil && !c.Writer.Written() {
			if errors.Is(err, playback.ErrExpired) {
				c.String(http.StatusGone, "Playback session expired; reopen the file")
			} else {
				c.String(http.StatusBadGateway, "Playback source cache failed")
			}
		}
		return
	}
	session, err := playbackManager.Get(id)
	if err != nil {
		c.String(http.StatusGone, "Playback session expired; reopen the file")
		return
	}
	if resource == "index.m3u8" {
		c.Header("Content-Type", "application/vnd.apple.mpegurl")
		http.ServeContent(c.Writer, c.Request, resource, time.Time{}, bytes.NewReader(session.Playlist()))
		return
	}
	indexText, ok := strings.CutSuffix(resource, ".m4s")
	index, parseErr := strconv.Atoi(indexText)
	if !ok || parseErr != nil || index < 0 || strconv.Itoa(index) != indexText || index >= len(session.Index.Boundaries)-1 {
		c.Status(http.StatusNotFound)
		return
	}
	c.Header("Content-Type", "video/mp4")
	if c.Request.Method == http.MethodHead {
		c.Status(http.StatusOK)
		return
	}
	select {
	case playbackTransfers <- struct{}{}:
		defer func() { <-playbackTransfers }()
	default:
		c.Header("Retry-After", "2")
		c.String(http.StatusServiceUnavailable, "Playback transfer capacity reached")
		return
	}
	data, err := playbackManager.Segment(c.Request.Context(), id, index)
	if err != nil {
		switch {
		case errors.Is(err, playback.ErrBusy):
			c.Header("Retry-After", "2")
			c.String(http.StatusServiceUnavailable, "Playback capacity reached; retry shortly")
		case errors.Is(err, playback.ErrExpired):
			c.String(http.StatusGone, "Playback session expired; reopen the file")
		default:
			c.String(http.StatusBadGateway, "Compatible media segment could not be generated")
		}
		return
	}
	http.ServeContent(c.Writer, c.Request, resource, time.Time{}, bytes.NewReader(data))
}
