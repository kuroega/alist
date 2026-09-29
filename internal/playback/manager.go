package playback

import (
	"container/list"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	log "github.com/sirupsen/logrus"
)

var (
	ErrNotNeeded    = errors.New("playback conversion is not applicable")
	ErrBusy         = errors.New("playback capacity is exhausted")
	ErrExpired      = errors.New("playback session has expired")
	errSource       = errors.New("playback source range request failed")
	errRange        = errors.New("playback source did not return the exact requested range")
	errReadLimit    = errors.New("playback index exceeds the read limit")
	errSegmentLimit = errors.New("playback segment exceeds the output limit")
)

const (
	probeTimeout       = 45 * time.Second
	rangeTimeout       = 15 * time.Second
	encodeTimeout      = 2 * time.Minute
	maxSegmentBytes    = 64 << 20
	rangePageBytes     = 64 << 10
	maxRangeRead       = 16 << 20
	maxProbeBytes      = 16 << 20
	maxIndexBoundaries = 100001
)

type Config struct {
	FFmpeg              string
	MaxSessions         int
	MaxConcurrent       int
	MaxCacheBytes       int64
	IdleTimeout         time.Duration
	SourceCacheDir      string
	MaxSourceCacheBytes int64
	SourceChunkBytes    int64
	SourceBaseURL       string
}

type Session struct {
	ID    string
	Index Index

	key        string
	identity   string
	sourceURL  string
	source     *sourceEntry
	lastAccess time.Time
	ctx        context.Context
	cancel     context.CancelFunc
	segments   map[int]*segmentCall
	// init is the shared fMP4 initialization segment (ftyp+moov) served as
	// EXT-X-MAP. HLS media segments must not carry their own init data, so it
	// is captured from the first encoded segment and reused for the session.
	init []byte
}

// Playlist uses the continuous timeline applied by shiftSegmentTimeline.
// Each encoder run must first trim seek preroll to its indexed interval.
func (s *Session) Playlist() []byte {
	var b strings.Builder
	longest := 0.0
	for n := 1; n < len(s.Index.Boundaries); n++ {
		longest = math.Max(longest, s.Index.Boundaries[n]-s.Index.Boundaries[n-1])
	}
	fmt.Fprintf(&b, "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%.0f\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n", math.Ceil(longest))
	for n := 0; n+1 < len(s.Index.Boundaries); n++ {
		fmt.Fprintf(&b, "#EXTINF:%s,\n%d.m4s\n", seconds(s.Index.Boundaries[n+1]-s.Index.Boundaries[n]), n)
	}
	b.WriteString("#EXT-X-ENDLIST\n")
	return []byte(b.String())
}

type openCall struct {
	done    chan struct{}
	cancel  context.CancelFunc
	session *Session
	err     error
}

type segmentCall struct {
	done chan struct{}
	data []byte
	err  error
}

type cacheKey struct {
	id string
	n  int
}

type cacheEntry struct {
	key  cacheKey
	data []byte
}

type negativeEntry struct {
	identity   string
	lastAccess time.Time
}

type Manager struct {
	mu         sync.Mutex
	config     Config
	ffmpeg     string
	client     *http.Client
	sources    *sourceStore
	sourceErr  error
	ctx        context.Context
	cancel     context.CancelFunc
	now        func() time.Time
	closed     bool
	sessions   map[string]*Session
	keys       map[string]*Session
	identities map[string]string
	opening    map[string]*openCall
	negative   map[string]negativeEntry
	slots      chan struct{}
	cache      map[cacheKey]*list.Element
	lru        list.List
	cacheBytes int64
}

func NewManager(config Config) *Manager {
	if config.FFmpeg == "" {
		config.FFmpeg = "ffmpeg"
	}
	if config.MaxSessions <= 0 {
		config.MaxSessions = 8
	}
	if config.MaxConcurrent <= 0 {
		config.MaxConcurrent = 1
	}
	if config.MaxCacheBytes <= 0 {
		config.MaxCacheBytes = 128 << 20
	}
	if config.IdleTimeout <= 0 {
		config.IdleTimeout = 30 * time.Minute
	}
	ffmpeg, _ := exec.LookPath(config.FFmpeg)
	ctx, cancel := context.WithCancel(context.Background())
	transport := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: rangeTimeout, KeepAlive: 30 * time.Second}).DialContext,
		DisableCompression:    true,
		MaxIdleConns:          config.MaxSessions,
		MaxIdleConnsPerHost:   config.MaxSessions,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   rangeTimeout,
		ResponseHeaderTimeout: rangeTimeout,
	}
	manager := &Manager{
		config: config,
		ffmpeg: ffmpeg,
		client: &http.Client{
			Transport:     transport,
			Timeout:       rangeTimeout,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return errSource },
		},
		ctx:        ctx,
		cancel:     cancel,
		now:        time.Now,
		sessions:   make(map[string]*Session),
		keys:       make(map[string]*Session),
		identities: make(map[string]string),
		opening:    make(map[string]*openCall),
		negative:   make(map[string]negativeEntry),
		slots:      make(chan struct{}, config.MaxConcurrent),
		cache:      make(map[cacheKey]*list.Element),
	}
	sourceTransport := transport.Clone()
	sourceTransport.ResponseHeaderTimeout = sourceChunkTimeout
	sourceClient := &http.Client{
		Transport: sourceTransport, Timeout: sourceChunkTimeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return errSource },
	}
	manager.sources, manager.sourceErr = newSourceStore(
		config.SourceCacheDir, config.MaxSourceCacheBytes, config.SourceChunkBytes, sourceClient,
	)
	if manager.sources != nil && !validSourceBase(config.SourceBaseURL) {
		manager.sourceErr = errors.New("invalid playback source cache URL")
	}
	return manager
}

// Open accepts only signed original-file URLs generated by the server itself.
// The key's final NUL separates the user/path identity from size/mtime revision.
func (m *Manager) Open(ctx context.Context, key, sourceURL string, size int64) (*Session, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if key == "" || size <= 0 || !validSource(sourceURL) {
		return nil, errors.New("invalid playback source")
	}
	if m.sourceErr != nil {
		return nil, errors.New("playback source cache is unavailable")
	}
	identity := key
	if n := strings.LastIndexByte(key, 0); n >= 0 {
		identity = key[:n]
	}
	m.mu.Lock()
	m.expireLocked()
	if m.closed {
		m.mu.Unlock()
		return nil, ErrExpired
	}
	if s := m.keys[key]; s != nil {
		s.lastAccess = m.now()
		if s.source != nil {
			s.source.setSourceURL(sourceURL)
		} else {
			s.sourceURL = sourceURL
		}
		m.mu.Unlock()
		return s, nil
	}
	if entry, ok := m.negative[key]; ok {
		entry.lastAccess = m.now()
		m.negative[key] = entry
		m.mu.Unlock()
		return nil, ErrNotNeeded
	}
	if call := m.opening[key]; call != nil {
		m.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-call.done:
			return call.session, call.err
		}
	}
	if previous := m.identities[identity]; previous != "" && previous != key {
		if _, ok := m.negative[previous]; ok {
			m.removeNegativeLocked(previous)
		}
		if s := m.keys[previous]; s != nil {
			m.removeSessionLocked(s)
		}
		if call := m.opening[previous]; call != nil {
			call.cancel()
		}
	}
	if len(m.sessions)+len(m.opening) >= m.config.MaxSessions {
		m.mu.Unlock()
		return nil, ErrBusy
	}
	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	stop := context.AfterFunc(m.ctx, cancel)
	call := &openCall{done: make(chan struct{}), cancel: cancel}
	m.opening[key] = call
	m.identities[identity] = key
	m.mu.Unlock()

	var cachedSource *sourceEntry
	var err error
	if m.sources != nil {
		cachedSource, err = m.sources.acquire(sourceCacheIdentity(key), sourceURL, size)
	}
	var index Index
	if err == nil {
		index, err = m.probe(probeCtx, sourceURL, size)
	}
	if err == nil {
		err = probeCtx.Err()
	}
	stop()
	cancel()

	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.opening, key)
	if m.closed || m.identities[identity] != key {
		err = ErrExpired
	}
	if err == nil {
		var random [32]byte
		if _, err = rand.Read(random[:]); err != nil {
			err = errors.New("could not create playback session")
		} else {
			sessionCtx, sessionCancel := context.WithCancel(m.ctx)
			id := base64.RawURLEncoding.EncodeToString(random[:])
			playbackSource := sourceURL
			if cachedSource != nil {
				playbackSource = strings.TrimRight(m.config.SourceBaseURL, "/") + "/" + id + "/source"
			}
			s := &Session{
				ID: id, Index: index,
				key: key, identity: identity, sourceURL: playbackSource, source: cachedSource, lastAccess: m.now(),
				ctx: sessionCtx, cancel: sessionCancel, segments: make(map[int]*segmentCall),
			}
			m.sessions[s.ID] = s
			m.keys[key] = s
			call.session = s
		}
	}
	if err != nil && cachedSource != nil {
		m.sources.release(cachedSource)
	}
	if errors.Is(err, ErrNotNeeded) {
		m.cacheNegativeLocked(key, identity)
	} else if err != nil && m.identities[identity] == key {
		delete(m.identities, identity)
	}
	call.err = err
	close(call.done)
	return call.session, call.err
}

func validSource(source string) bool {
	u, err := url.Parse(source)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Fragment != "" {
		return false
	}
	ip := net.ParseIP(u.Hostname())
	return ip != nil && ip.IsLoopback() && strings.Contains(u.Path, "/p/") &&
		u.Query().Get("sign") != "" && u.Query().Get("internal_playback") == "1"
}
func validSourceBase(source string) bool {
	u, err := url.Parse(source)
	if err != nil || u.Scheme != "http" || u.User != nil || u.Fragment != "" {
		return false
	}
	ip := net.ParseIP(u.Hostname())
	return ip != nil && ip.IsLoopback()
}

func sourceCacheIdentity(key string) string {
	if n := strings.IndexByte(key, 0); n >= 0 {
		return key[n+1:]
	}
	return key
}

func (m *Manager) probe(ctx context.Context, sourceURL string, size int64) (Index, error) {
	r := &rangeReader{ctx: ctx, client: m.client, sourceURL: sourceURL, size: size}
	index, err := ReadIndex(r, size)
	if err != nil {
		if ctx.Err() != nil {
			return Index{}, ctx.Err()
		}
		// Keep network failures explicit even if an unsupported EBML structure
		// wraps them. Never include the URL-bearing net/http error.
		if r.err != nil {
			return Index{}, r.err
		}
		if errors.Is(err, ErrUnsupported) {
			return Index{}, ErrNotNeeded
		}
		return Index{}, errors.New("could not read playback index")
	}
	if (index.VideoCodec != "hevc" && index.VideoCodec != "h264") ||
		(index.AudioCodec != "truehd" && index.AudioCodec != "dts" && index.AudioCodec != "ac3" && index.AudioCodec != "eac3") {
		return Index{}, ErrNotNeeded
	}
	if !validIndex(index) {
		return Index{}, errors.New("invalid playback timeline")
	}
	if m.ffmpeg == "" {
		return Index{}, errors.New("playback FFmpeg executable is unavailable")
	}
	return index, nil
}

func validIndex(index Index) bool {
	if math.IsNaN(index.Duration) || math.IsInf(index.Duration, 0) || index.Duration <= 0 ||
		len(index.Boundaries) < 2 || len(index.Boundaries) > maxIndexBoundaries ||
		len(index.seekTimes) != len(index.Boundaries)-1 ||
		index.Boundaries[0] != 0 || index.Boundaries[len(index.Boundaries)-1] != index.Duration {
		return false
	}
	for n := 1; n < len(index.Boundaries); n++ {
		if math.IsNaN(index.Boundaries[n]) || math.IsInf(index.Boundaries[n], 0) || index.Boundaries[n] <= index.Boundaries[n-1] {
			return false
		}
		seek := index.seekTimes[n-1]
		if math.IsNaN(seek) || math.IsInf(seek, 0) || seek < index.Boundaries[n-1] || seek >= index.Boundaries[n] {
			return false
		}
	}
	return true
}

func (m *Manager) Get(id string) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.expireLocked()
	s := m.sessions[id]
	if s == nil || m.closed {
		return nil, ErrExpired
	}
	s.lastAccess = m.now()
	return s, nil
}

// Source serves the session's original bytes through the persistent read-through
// cache. The HTTP handler restricts this method to the loopback FFmpeg client.
func (m *Manager) Source(w http.ResponseWriter, r *http.Request, id string) error {
	m.mu.Lock()
	m.expireLocked()
	s := m.sessions[id]
	if s == nil || m.closed {
		m.mu.Unlock()
		return ErrExpired
	}
	if s.source == nil {
		m.mu.Unlock()
		return ErrNotNeeded
	}
	s.lastAccess = m.now()
	source := s.source
	m.sources.retain(source)
	m.mu.Unlock()
	defer m.sources.release(source)
	return source.serve(w, r)
}

// Segment returns immutable cached bytes, or encodes just the requested interval.
// The first request owns an encode; abandoning it cancels that process and wakes
// duplicate waiters with an explicit error, rather than leaving background work.
func (m *Manager) Segment(ctx context.Context, id string, n int) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.expireLocked()
	s := m.sessions[id]
	if s == nil || m.closed {
		m.mu.Unlock()
		return nil, ErrExpired
	}
	if n < 0 || n >= len(s.Index.Boundaries)-1 {
		m.mu.Unlock()
		return nil, errors.New("invalid playback segment")
	}
	s.lastAccess = m.now()
	key := cacheKey{id, n}
	if entry := m.cache[key]; entry != nil {
		m.lru.MoveToFront(entry)
		data := entry.Value.(cacheEntry).data
		m.mu.Unlock()
		return data, nil
	}
	if call := s.segments[n]; call != nil {
		m.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-call.done:
			return call.data, call.err
		}
	}
	select {
	case m.slots <- struct{}{}:
	default:
		m.mu.Unlock()
		return nil, ErrBusy
	}
	call := &segmentCall{done: make(chan struct{})}
	s.segments[n] = call
	sourceURL := s.sourceURL
	start := s.Index.Boundaries[n]
	duration := s.Index.Boundaries[n+1] - start
	seek := s.Index.seekTimes[n]
	videoCodec := s.Index.VideoCodec
	m.mu.Unlock()

	encodeCtx, cancel := context.WithTimeout(ctx, encodeTimeout)
	stop := context.AfterFunc(s.ctx, cancel)
	encodeStart := time.Now()
	data, err := m.encode(encodeCtx, cancel, sourceURL, videoCodec, seek, start, duration)
	if err == nil {
		err = encodeCtx.Err()
	}
	if err == nil {
		// Segments are encoded independently, so ffmpeg restarts the fragment
		// sequence at 1 for every segment. VLC 4 interprets that reset as a
		// passive seek (FragPrepareChunk with a discontinuity) and loses
		// inter-frame prediction. Rebase each segment to one contiguous global
		// sequence in playlist order.
		fragments, seqErr := renumberFragments(data, uint32(n)+1)
		if seqErr != nil {
			err = seqErr
		} else if fragments != 1 {
			err = fmt.Errorf("playback segment %d emitted %d fragments, want 1", n, fragments)
		}
	}
	stop()
	cancel()
	// No URLs, paths, or session IDs: segment index, byte size, and wall
	// time only. Used to separate encoder/source latency from delivery.
	log.Infof("playback segment %d: %d bytes in %s err=%v", n, len(data), time.Since(encodeStart).Round(time.Millisecond), err)

	m.mu.Lock()
	<-m.slots
	delete(s.segments, n)
	if m.closed || m.sessions[id] != s {
		err = ErrExpired
	}
	if err == nil {
		if s.init == nil {
			if init, _, ok := splitInit(data); ok {
				// Copy: the init must not pin the whole segment buffer in memory.
				s.init = append([]byte(nil), init...)
			}
		}
		m.cacheSegmentLocked(key, data)
		call.data = data
	}
	call.err = err
	close(call.done)
	m.mu.Unlock()
	return call.data, call.err
}

// Init returns the shared fMP4 initialization segment (ftyp+moov) for a
// session's EXT-X-MAP. It is captured from the first successfully encoded
// segment; if none is available yet it encodes segment 0 to derive one.
func (m *Manager) Init(ctx context.Context, id string) ([]byte, error) {
	m.mu.Lock()
	m.expireLocked()
	s := m.sessions[id]
	if s == nil || m.closed {
		m.mu.Unlock()
		return nil, ErrExpired
	}
	if s.init != nil {
		data := s.init
		m.mu.Unlock()
		return data, nil
	}
	m.mu.Unlock()
	if _, err := m.Segment(ctx, id, 0); err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.expireLocked()
	defer m.mu.Unlock()
	s = m.sessions[id]
	if s == nil || m.closed {
		return nil, ErrExpired
	}
	if s.init == nil {
		return nil, errors.New("playback initialization segment unavailable")
	}
	return s.init, nil
}

func (m *Manager) encode(ctx context.Context, cancel context.CancelFunc, sourceURL, videoCodec string, seek, start, duration float64) ([]byte, error) {
	limit := min(int64(maxSegmentBytes), m.config.MaxCacheBytes)
	out := &segmentBuffer{limit: int(limit), cancel: cancel}
	bsf := "h264_mp4toannexb"
	if videoCodec == "hevc" {
		// Dolby Vision RPU rides as HEVC UNSPEC62 NAL units on profile 5/8
		// sources. Browsers without a DV path render the copied stream as
		// black video, so drop type 62 and keep the HDR10 base layer.
		// NOTE: keep stream copy (no re-encode): software HEVC/HDR
		// transcoding cannot sustain realtime on the 1-vCPU VM.
		bsf = "hevc_mp4toannexb,filter_units=remove_types=62"
	}
	// Input seeking preserves video packets from the preceding keyframe when
	// stream-copying (audio is accurately trimmed). Drop that negative-PTS
	// preroll before the MP4 muxer normalizes timestamps, and exclude the next
	// interval's frames. Otherwise a 10-second interval can contain 15 seconds
	// of video but only 10 seconds of audio, overlapping the following segment.
	bsf += fmt.Sprintf(",noise=drop='lt(pts*tb,0)+gte(pts*tb,%s)'", seconds(duration))
	// Independently encoded AAC is emitted in whole 1024-sample frames.
	// Anchor the number of decoded frames to a single global sample grid;
	// rounding each segment's duration independently leaves a partial last
	// packet which decoders render as a full frame, accumulating A/V drift.
	const aacFrame = 1024.0 / 48000
	firstFrame := math.Round(start / aacFrame)
	lastFrame := math.Round((start + duration) / aacFrame)
	audioInputSamples := int64(lastFrame-firstFrame-1) * 1024 // encoder adds one priming frame
	if audioInputSamples < 0 {
		return nil, errors.New("playback segment is too short for AAC")
	}
	args := []string{
		"-hide_banner", "-nostdin", "-loglevel", "warning", "-xerror",
		"-abort_on", "empty_output+empty_output_stream",
		"-rw_timeout", "15000000", "-protocol_whitelist", "http,https,tcp,tls,crypto",
		"-probesize", "1048576", "-analyzeduration", "1000000",
		// Seek inside the indexed GOP to avoid downloading the preceding GOP.
		// Retain preroll and restore the boundary's timestamp origin; the video
		// bitstream filter and audio resampler trim against that shared origin.
		"-seek_timestamp", "1", "-ss", seconds(seek), "-itsoffset", seconds(seek - start),
		"-noaccurate_seek", "-i", sourceURL,
		// Allow the final complete AAC frame past the video boundary; video
		// packets beyond the boundary are removed by the bitstream filter.
		"-t", seconds(duration + 2*aacFrame), "-map", "0:v:0", "-map", "0:a:0",
		"-map_metadata", "-1", "-map_chapters", "-1", "-sn", "-dn",
		"-c:v", "copy", "-bsf:v", bsf,
		"-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000", "-threads:a", "1",
		// Trim negative seek preroll and fill any initial audio gap against
		// video's origin; never reset audio independently with PTS-STARTPTS.
		// Exactly N-1 input frames produce N AAC packets including priming.
		// Do not use a fractional atrim duration: its last packet advertises
		// a short duration but still decodes to a whole frame in HLS players.
		"-af", fmt.Sprintf("aresample=48000:async=1:first_pts=0,atrim=end_sample=%d", audioInputSamples), "-filter_threads", "1",
		"-max_muxing_queue_size", "1024", "-avoid_negative_ts", "make_non_negative",
		// Fragmented MP4 with one fragment per segment: players use
		// ffmpeg-written decoder configuration instead of demuxer-built config
		// from a transport stream, which strict decoders rejected with black
		// video. A single moof per segment lets the fragment sequence number be
		// made globally contiguous across the playlist; VLC treats a gap as a
		// passive seek and resets prediction. Apply the playlist origin to the
		// emitted decode timestamps below.
		"-movflags", "+empty_moov+default_base_moof",
		"-frag_duration", strconv.FormatInt(int64((duration+1)*1e6), 10),
		"-f", "mp4", "pipe:1",
	}
	stderr := &stderrTail{}
	cmd := exec.CommandContext(ctx, m.ffmpeg, args...)
	cmd.Stdout = out
	// FFmpeg diagnostics can contain signed source URLs, so retain a bounded
	// tail in memory and redact it before anything reaches a log. A 326 ms,
	// zero-byte conversion failure previously left no trace at all.
	cmd.Stderr = stderr
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()
	if out.exceeded {
		return nil, errSegmentLimit
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		detail := sanitizedConverterDetail(string(stderr.buf), sourceURL)
		if stderr.truncated {
			detail = "[earlier output omitted] " + detail
		}
		if detail == "" {
			return nil, fmt.Errorf("playback segment conversion failed: %w", err)
		}
		return nil, fmt.Errorf("playback segment conversion failed: %w: %s", err, detail)
	}
	if len(out.data) == 0 || !validFragmentedMP4(out.data) {
		return nil, errors.New("playback encoder returned invalid fragmented MP4")
	}
	if err := shiftSegmentTimeline(out.data, start); err != nil {
		return nil, fmt.Errorf("playback segment timeline: %w", err)
	}
	if err := alignAACFrameTimeline(out.data, uint64(firstFrame)*1024); err != nil {
		return nil, fmt.Errorf("playback segment AAC timeline: %w", err)
	}
	return out.data, nil
}

const (
	// Keep enough trailer to see the fatal reason without unbounded memory.
	ffmpegStderrLimit = 16 << 10
	// Failure details are logged, so bound them to one readable line.
	ffmpegDetailLimit = 1024
)

var (
	// Whole http(s) URLs may embed signed paths or queries; drop them.
	ffmpegURLPattern = regexp.MustCompile(`(?i)https?://\S+`)
	// Capability parameters can also appear without a URL prefix.
	ffmpegSecretPattern = regexp.MustCompile(`(?i)\b(sign|token|api_?key|access_?key|authorization|cookie|password)=[^\s&'"]*`)
)

// stderrTail retains only the most recent ffmpeg diagnostics. Raw stderr can
// contain signed source URLs, so callers must redact it before logging.
type stderrTail struct {
	buf       []byte
	truncated bool
}

func (s *stderrTail) Write(p []byte) (int, error) {
	s.buf = append(s.buf, p...)
	if len(s.buf) > ffmpegStderrLimit {
		n := copy(s.buf, s.buf[len(s.buf)-ffmpegStderrLimit:])
		s.buf = s.buf[:n]
		s.truncated = true
	}
	return len(p), nil
}

// sanitizedConverterDetail turns ffmpeg stderr into one log-safe line. Signed
// player capabilities must never leave here, so the exact source URL, any
// http(s) URL, and common secret parameters are redacted first.
func sanitizedConverterDetail(stderr, sourceURL string) string {
	text := stderr
	if sourceURL != "" {
		text = strings.ReplaceAll(text, sourceURL, "<source>")
	}
	text = ffmpegSecretPattern.ReplaceAllString(text, "$1=<redacted>")
	text = ffmpegURLPattern.ReplaceAllString(text, "<url>")
	text = strings.Join(strings.Fields(text), " ")
	if text == "" {
		return ""
	}
	if len(text) > ffmpegDetailLimit {
		// Keep the tail: ffmpeg prints the fatal reason last.
		text = "…" + text[len(text)-ffmpegDetailLimit:]
	}
	return text
}

// validFragmentedMP4 checks the leading boxes of one self-initialized
// segment: ftyp first, then moov (empty, from empty_moov) within the first
// megabyte, before any moof/mdat. Full-file validation is unnecessary; the
// player verifies media samples.
func validFragmentedMP4(data []byte) bool {
	if len(data) < 8 || string(data[4:8]) != "ftyp" {
		return false
	}
	const scanLimit = 1 << 20
	end := min(len(data), scanLimit)
	off := 0
	for off+8 <= end {
		size := int(uint32(data[off])<<24 | uint32(data[off+1])<<16 | uint32(data[off+2])<<8 | uint32(data[off+3]))
		typ := string(data[off+4 : off+8])
		if typ == "moov" {
			return true
		}
		if size < 8 {
			return false
		}
		off += size
	}
	return false
}

func seconds(value float64) string {
	return strconv.FormatFloat(value, 'f', -1, 64)
}

func (m *Manager) cacheSegmentLocked(key cacheKey, data []byte) {
	if old := m.cache[key]; old != nil {
		m.removeCacheLocked(old)
	}
	// The cache retains the backing allocation, not just the payload.
	cost := int64(cap(data))
	if cost > m.config.MaxCacheBytes {
		return
	}
	for m.cacheBytes+cost > m.config.MaxCacheBytes {
		m.removeCacheLocked(m.lru.Back())
	}
	entry := m.lru.PushFront(cacheEntry{key: key, data: data})
	m.cache[key] = entry
	m.cacheBytes += cost
}

func (m *Manager) removeCacheLocked(entry *list.Element) {
	value := entry.Value.(cacheEntry)
	delete(m.cache, value.key)
	m.cacheBytes -= int64(cap(value.data))
	m.lru.Remove(entry)
}

func (m *Manager) removeSessionLocked(s *Session) {
	s.cancel()
	if s.source != nil {
		m.sources.release(s.source)
	}
	delete(m.sessions, s.ID)
	delete(m.keys, s.key)
	if m.identities[s.identity] == s.key {
		delete(m.identities, s.identity)
	}
	for key, entry := range m.cache {
		if key.id == s.ID {
			m.removeCacheLocked(entry)
		}
	}
}

func (m *Manager) removeNegativeLocked(key string) {
	entry := m.negative[key]
	delete(m.negative, key)
	if m.identities[entry.identity] == key {
		delete(m.identities, entry.identity)
	}
}

func (m *Manager) cacheNegativeLocked(key, identity string) {
	if len(m.negative) >= m.config.MaxSessions {
		oldest := ""
		for candidate, entry := range m.negative {
			if oldest == "" || entry.lastAccess.Before(m.negative[oldest].lastAccess) {
				oldest = candidate
			}
		}
		m.removeNegativeLocked(oldest)
	}
	m.negative[key] = negativeEntry{identity: identity, lastAccess: m.now()}
	m.identities[identity] = key
}

func (m *Manager) expireLocked() {
	now := m.now()
	for _, s := range m.sessions {
		if now.Sub(s.lastAccess) >= m.config.IdleTimeout {
			m.removeSessionLocked(s)
		}
	}
	for key, entry := range m.negative {
		if now.Sub(entry.lastAccess) >= m.config.IdleTimeout {
			m.removeNegativeLocked(key)
		}
	}
}

func (m *Manager) Close() {
	m.mu.Lock()
	m.closed = true
	m.cancel()
	for _, s := range m.sessions {
		m.removeSessionLocked(s)
	}
	for key := range m.negative {
		m.removeNegativeLocked(key)
	}
	m.mu.Unlock()
	m.client.CloseIdleConnections()
}

type segmentBuffer struct {
	data     []byte
	limit    int
	cancel   context.CancelFunc
	exceeded bool
}

func (b *segmentBuffer) Write(p []byte) (int, error) {
	if len(p) > b.limit-len(b.data) {
		b.exceeded = true
		b.cancel()
		return 0, errSegmentLimit
	}
	needed := len(b.data) + len(p)
	if needed > cap(b.data) {
		capacity := min(b.limit, max(needed, max(64<<10, cap(b.data)*2)))
		data := make([]byte, len(b.data), capacity)
		copy(data, b.data)
		b.data = data
	}
	b.data = append(b.data, p...)
	return len(p), nil
}

type rangePage struct {
	offset int64
	data   []byte
}

// Four pages amortize tiny EBML reads without keeping a full file or its index
// in the HTTP reader. ReadAt is serialized so budgets also hold for callers
// issuing concurrent reads.
type rangeReader struct {
	mu        sync.Mutex
	ctx       context.Context
	client    *http.Client
	sourceURL string
	size      int64
	bytes     int64
	pages     [4]rangePage
	nextPage  int
	err       error
}

func (r *rangeReader) ReadAt(p []byte, off int64) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(p) == 0 {
		return 0, nil
	}
	if off < 0 {
		return 0, errors.New("invalid playback source offset")
	}
	if off >= r.size {
		return 0, io.EOF
	}
	if len(p) > maxRangeRead {
		r.err = errReadLimit
		return 0, r.err
	}
	length := min(int64(len(p)), r.size-off)
	n := 0
	for int64(n) < length {
		if err := r.ctx.Err(); err != nil {
			r.err = err
			return n, err
		}
		position := off + int64(n)
		pageOffset := position / rangePageBytes * rangePageBytes
		var data []byte
		for _, page := range r.pages {
			if page.offset == pageOffset && page.data != nil {
				data = page.data
				break
			}
		}
		if data == nil {
			var err error
			data, err = r.fetch(pageOffset)
			if err != nil {
				r.err = err
				return n, err
			}
			r.pages[r.nextPage] = rangePage{offset: pageOffset, data: data}
			r.nextPage = (r.nextPage + 1) % len(r.pages)
		}
		count := min(int(length)-n, len(data)-int(position-pageOffset))
		copy(p[n:n+count], data[position-pageOffset:position-pageOffset+int64(count)])
		n += count
	}
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}

func (r *rangeReader) fetch(off int64) ([]byte, error) {
	length := min(int64(rangePageBytes), r.size-off)
	if r.bytes+length > maxProbeBytes {
		return nil, errReadLimit
	}
	r.bytes += length
	ctx, cancel := context.WithTimeout(r.ctx, rangeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.sourceURL, nil)
	if err != nil {
		return nil, errSource
	}
	end := off + length - 1
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", off, end))
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := r.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errSource
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent ||
		resp.Header.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", off, end, r.size) ||
		(resp.ContentLength >= 0 && resp.ContentLength != length) ||
		(resp.Header.Get("Content-Encoding") != "" && resp.Header.Get("Content-Encoding") != "identity") {
		return nil, errRange
	}
	data := make([]byte, int(length))
	if _, err := io.ReadFull(resp.Body, data); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errRange
	}
	var extra [1]byte
	if n, err := resp.Body.Read(extra[:]); n != 0 || err != io.EOF {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errRange
	}
	return data, nil
}
