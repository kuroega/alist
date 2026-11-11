package handles

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alist-org/alist/v3/internal/playback"
	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
	"github.com/sirupsen/logrus/hooks/test"
)

func TestPlaybackResponseLogNamesBusyRejectionByTag(t *testing.T) {
	gin.SetMode(gin.TestMode)
	hook := test.NewGlobal()
	defer hook.Reset()
	id := "bearer-capability-id"

	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodGet, "/playback/"+id+"/92.m4s", nil)
	c.String(http.StatusServiceUnavailable, "Playback capacity reached; retry shortly")
	logPlaybackResponse(c, playback.SessionTag(id), "92.m4s", time.Now(), playback.ErrBusy)

	entry := hook.LastEntry()
	if entry == nil || entry.Level != log.WarnLevel {
		t.Fatalf("busy rejection logged as %v, want a warning", entry)
	}
	line := entry.Message
	for _, want := range []string{playback.SessionTag(id), "92.m4s", "status 503", playback.ErrBusy.Error()} {
		if !strings.Contains(line, want) {
			t.Errorf("log %q lacks %q", line, want)
		}
	}
	if strings.Contains(line, id) {
		t.Errorf("log %q exposes the session capability", line)
	}
}

func TestPlaybackResponseLogKeepsServedSegmentsAtInfo(t *testing.T) {
	gin.SetMode(gin.TestMode)
	hook := test.NewGlobal()
	defer hook.Reset()

	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodGet, "/playback/id/5.m4s", nil)
	c.Data(http.StatusOK, "video/mp4", make([]byte, 1234))
	logPlaybackResponse(c, "0a1b2c3d", "5.m4s", time.Now(), nil)

	entry := hook.LastEntry()
	if entry == nil || entry.Level != log.InfoLevel || !strings.Contains(entry.Message, "status 200, 1234 bytes") {
		t.Fatalf("served segment logged as %v", entry)
	}
}

// Matroska releases are often named .mp4; the probe, not the name, decides.
// A Dolby Vision profile 5 file named .mp4 previously skipped the session and
// played its raw IPTPQc2 base layer in VLC (purple and green).
func TestMayBeMatroska(t *testing.T) {
	for name, want := range map[string]bool{
		"movie.mkv": true, "S01E32.mp4": true, "SHOW.MP4": true, "clip.m4v": true, "clip.mov": true,
		"index.m3u8": false, "poster.jpg": false, "sub.ass": false, "noext": false,
	} {
		if got := mayBeMatroska(name); got != want {
			t.Errorf("%s: got %v, want %v", name, got, want)
		}
	}
}
