package playback

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRangeReaderReadsAcrossPagesAndEOF(t *testing.T) {
	data := make([]byte, rangePageBytes*3+7)
	for n := range data {
		data[n] = byte(n * 31)
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Header.Get("Range") == "" || r.Header.Get("Accept-Encoding") != "identity" {
			http.Error(w, "range required", http.StatusBadRequest)
			return
		}
		http.ServeContent(w, r, "movie.mkv", time.Time{}, bytes.NewReader(data))
	}))
	defer server.Close()
	r := &rangeReader{ctx: context.Background(), client: server.Client(), sourceURL: server.URL, size: int64(len(data))}
	p := make([]byte, 8)
	if n, err := r.ReadAt(p, rangePageBytes-2); n != len(p) || err != nil || !bytes.Equal(p, data[rangePageBytes-2:rangePageBytes+6]) {
		t.Fatalf("cross-page read: n=%d data=%v err=%v", n, p, err)
	}
	if _, err := r.ReadAt(p[:1], rangePageBytes+3); err != nil {
		t.Fatal(err)
	}
	if got := requests.Load(); got != 2 {
		t.Fatalf("adjacent EBML reads fetched %d HTTP pages, want 2", got)
	}
	if n, err := r.ReadAt(p, int64(len(data)-2)); n != 2 || !errors.Is(err, io.EOF) || !bytes.Equal(p[:2], data[len(data)-2:]) {
		t.Fatalf("partial EOF: n=%d data=%v err=%v", n, p[:2], err)
	}
}

func TestRangeReaderRejectsInvalidResponses(t *testing.T) {
	cases := []struct {
		name          string
		status        int
		contentRange  string
		contentLength string
		encoding      string
		body          string
		chunked       bool
	}{
		{name: "ignored range", status: 200, body: "12345678"},
		{name: "wrong start", status: 206, contentRange: "bytes 1-7/8", body: "12345678"},
		{name: "changed source size", status: 206, contentRange: "bytes 0-7/9", body: "12345678"},
		{name: "truncated range", status: 206, contentRange: "bytes 0-7/8", contentLength: "8", body: "1234567"},
		{name: "oversized chunked range", status: 206, contentRange: "bytes 0-7/8", body: "123456789", chunked: true},
		{name: "encoded range", status: 206, contentRange: "bytes 0-7/8", encoding: "gzip", body: "12345678"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Range", tc.contentRange)
				if tc.contentLength != "" {
					w.Header().Set("Content-Length", tc.contentLength)
				}
				if tc.encoding != "" {
					w.Header().Set("Content-Encoding", tc.encoding)
				}
				w.WriteHeader(tc.status)
				if tc.chunked {
					w.(http.Flusher).Flush()
				}
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			r := &rangeReader{ctx: context.Background(), client: server.Client(), sourceURL: server.URL + "?sign=private-token", size: 8}
			if n, err := r.ReadAt(make([]byte, 1), 0); n != 0 || !errors.Is(err, errRange) {
				t.Fatalf("invalid range accepted: n=%d err=%v", n, err)
			}
		})
	}
}

func TestRangeReaderCancellationClosesSourceRequest(t *testing.T) {
	entered := make(chan struct{})
	abandoned := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
		close(abandoned)
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := &rangeReader{ctx: ctx, client: server.Client(), sourceURL: server.URL, size: 8}
	result := make(chan error, 1)
	go func() {
		_, err := r.ReadAt(make([]byte, 1), 0)
		result <- err
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("source request did not arrive")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled range returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("canceled range did not return")
	}
	select {
	case <-abandoned:
	case <-time.After(5 * time.Second):
		t.Fatal("canceled range left the source request running")
	}
}

func TestRangeReaderRejectsRedirectAndSanitizesURL(t *testing.T) {
	var followed atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		followed.Add(1)
	}))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"?sign=private-token", http.StatusFound)
	}))
	defer server.Close()
	m := NewManager(Config{})
	defer m.Close()
	r := &rangeReader{ctx: context.Background(), client: m.client, sourceURL: server.URL + "?sign=private-token", size: 8}
	_, err := r.ReadAt(make([]byte, 1), 0)
	if !errors.Is(err, errSource) || strings.Contains(err.Error(), "private-token") || strings.Contains(err.Error(), server.URL) {
		t.Fatalf("unsafe range error: %v", err)
	}
	if followed.Load() != 0 {
		t.Fatal("followed a source redirect")
	}
}

func TestSegmentBufferCancelsBeforeExceedingLimit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b := &segmentBuffer{limit: 8, cancel: cancel}
	if n, err := b.Write([]byte("12345678")); n != 8 || err != nil {
		t.Fatalf("exact limit: n=%d err=%v", n, err)
	}
	if n, err := b.Write([]byte("9")); n != 0 || !errors.Is(err, errSegmentLimit) {
		t.Fatalf("overflow: n=%d err=%v", n, err)
	}
	if string(b.data) != "12345678" || cap(b.data) > b.limit || !errors.Is(ctx.Err(), context.Canceled) {
		t.Fatal("overflow changed accepted output, exceeded allocation cap, or failed to cancel the encoder")
	}
}

func TestDolbyVisionVariantOnlyForProfile5(t *testing.T) {
	for _, tc := range []struct {
		name   string
		codec  string
		config *DolbyVisionConfig
		offer  bool
	}{
		{"profile 5", "hevc", &DolbyVisionConfig{Profile: 5, Level: 6, RPU: true, BL: true}, true},
		// Profile 8 bases are HDR10 and play correctly without the RPU.
		{"profile 8.1", "hevc", &DolbyVisionConfig{Profile: 8, Level: 6, RPU: true, BL: true, Compatibility: 1}, false},
		// Dual-layer profile 7 needs its enhancement layer, which is not copied.
		{"profile 7", "hevc", &DolbyVisionConfig{Profile: 7, Level: 6, RPU: true, BL: true, EL: true}, false},
		{"no rpu", "hevc", &DolbyVisionConfig{Profile: 5, Level: 6, BL: true}, false},
		{"h264", "h264", &DolbyVisionConfig{Profile: 5, Level: 6, RPU: true, BL: true}, false},
		{"plain hevc", "hevc", nil, false},
	} {
		s := &Session{Index: Index{VideoCodec: tc.codec, DolbyVision: tc.config}}
		if got := s.DolbyVision() != nil; got != tc.offer || s.offers(DolbyVision) != tc.offer || !s.offers(Compatible) {
			t.Errorf("%s: offers Dolby Vision = %v, want %v", tc.name, got, tc.offer)
		}
	}
}

func TestDolbyVisionPlaylistUsesVariantResources(t *testing.T) {
	s := &Session{Index: Index{Duration: 14.2, Boundaries: []float64{0, 6.125, 14.2}}}
	playlist := string(s.Playlist(DolbyVision))
	if !strings.Contains(playlist, "#EXT-X-MAP:URI=\"dv-init.mp4\"\n") ||
		!strings.Contains(playlist, "\ndv-0.m4s\n") || !strings.Contains(playlist, "\ndv-1.m4s\n") {
		t.Fatalf("Dolby Vision playlist must reference only dv- resources:\n%s", playlist)
	}
	if strings.Contains(string(s.Playlist(Compatible)), "dv-") {
		t.Fatal("the compatible playlist must keep its original resource names")
	}
}

func TestPlaylistMatchesIndexedTimeline(t *testing.T) {
	s := &Session{Index: Index{Duration: 14.2, Boundaries: []float64{0, 6.125, 12.75, 14.2}}}
	playlist := string(s.Playlist(Compatible))
	if !strings.Contains(playlist, "#EXT-X-TARGETDURATION:7\n") || !strings.Contains(playlist, "#EXT-X-PLAYLIST-TYPE:VOD\n") || !strings.HasSuffix(playlist, "#EXT-X-ENDLIST\n") {
		t.Fatalf("invalid VOD playlist:\n%s", playlist)
	}
	// Apple's HLS authoring rules require an EXT-X-MAP for fMP4 media so
	// players initialize once and then consume media-only fragments.
	if !strings.Contains(playlist, "#EXT-X-MAP:URI=\"init.mp4\"\n") {
		t.Fatalf("fMP4 playlist is missing EXT-X-MAP:\n%s", playlist)
	}
	if mapAt, firstExtinf := strings.Index(playlist, "#EXT-X-MAP"), strings.Index(playlist, "#EXTINF:"); mapAt == -1 || mapAt > firstExtinf {
		t.Fatalf("EXT-X-MAP must precede the first segment:\n%s", playlist)
	}
	if strings.Contains(playlist, "#EXT-X-DISCONTINUITY\n") {
		t.Fatal("continuous-timeline playlist must not contain discontinuities")
	}
	lines := strings.Split(playlist, "\n")
	total := 0.0
	n := 0
	for i, line := range lines {
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		duration, err := strconv.ParseFloat(strings.TrimSuffix(strings.TrimPrefix(line, "#EXTINF:"), ","), 64)
		if err != nil || n >= len(s.Index.Boundaries)-1 || duration != s.Index.Boundaries[n+1]-s.Index.Boundaries[n] {
			t.Fatalf("segment %d duration does not match index: %s", n, line)
		}
		if i+1 >= len(lines) || lines[i+1] != fmt.Sprintf("%d.m4s", n) {
			t.Fatalf("segment %d has no relative seekable URL", n)
		}
		total += duration
		n++
	}
	if n != 3 || math.Abs(total-s.Index.Duration) > 1e-9 {
		t.Fatalf("playlist lost timeline: segments=%d duration=%v", n, total)
	}
}

func topBox(typ string, payload []byte) []byte {
	box := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(box, uint32(len(box)))
	copy(box[4:], typ)
	copy(box[8:], payload)
	return box
}

func moofBox(seq uint32) []byte {
	payload := make([]byte, 8)
	binary.BigEndian.PutUint32(payload[4:], seq)
	return topBox("moof", topBox("mfhd", payload))
}

func fragmentSequences(data []byte) []uint32 {
	var out []uint32
	walkTopBoxes(data, func(typ string, start, end, payload int) bool {
		if typ == "moof" {
			out = append(out, binary.BigEndian.Uint32(data[payload+12:payload+16]))
		}
		return true
	})
	return out
}

func TestSplitInitSeparatesInitializationFromMedia(t *testing.T) {
	init := append(topBox("ftyp", make([]byte, 8)), topBox("moov", make([]byte, 8))...)
	media := append(moofBox(1), topBox("mdat", make([]byte, 4))...)
	gotInit, gotMedia, ok := splitInit(append(append([]byte(nil), init...), media...))
	if !ok || !bytes.Equal(gotInit, init) || !bytes.Equal(gotMedia, media) {
		t.Fatalf("split failed: ok=%v init=%d media=%d", ok, len(gotInit), len(gotMedia))
	}
	if _, _, ok := splitInit(media); ok {
		t.Fatal("media without an init run must be rejected")
	}
	if _, _, ok := splitInit(init); ok {
		t.Fatal("init without media must be rejected")
	}
}

func TestRenumberFragmentsProducesContiguousSequence(t *testing.T) {
	single := moofBox(1)
	if n, err := renumberFragments(single, 7); err != nil || n != 1 {
		t.Fatalf("renumber one fragment: n=%d err=%v", n, err)
	}
	if got := fragmentSequences(single); len(got) != 1 || got[0] != 7 {
		t.Fatalf("sequence = %v, want [7]", got)
	}
	// Independently encoded segments each restart at 1; rebasing the second
	// segment must continue the first segment's sequence without a gap.
	two := append(moofBox(1), moofBox(1)...)
	if n, err := renumberFragments(two, 8); err != nil || n != 2 {
		t.Fatalf("renumber two fragments: n=%d err=%v", n, err)
	}
	if got := fragmentSequences(two); len(got) != 2 || got[0] != 8 || got[1] != 9 {
		t.Fatalf("sequence = %v, want [8 9]", got)
	}
	if _, err := renumberFragments(topBox("ftyp", nil), 1); err == nil {
		t.Fatal("data without a moof must be rejected")
	}
}

func TestSanitizedConverterDetailRedactsCapabilities(t *testing.T) {
	source := "http://127.0.0.1:8080/p/movie.mkv?sign=abc123&d=1"
	stderr := strings.Join([]string{
		source + ": Server returned 403 Forbidden",
		"Error while decoding stream #0:1: Invalid data found when processing input",
		"Opening 'http://upstream.example/private/movie.mkv?token=deadbeef' for reading",
		"sign=standalone-secret",
	}, "\n")
	detail := sanitizedConverterDetail(stderr, source)
	for _, secret := range []string{"abc123", "deadbeef", "standalone-secret", "/p/movie.mkv", "upstream.example"} {
		if strings.Contains(detail, secret) {
			t.Fatalf("capability %q leaked into converter detail: %q", secret, detail)
		}
	}
	if !strings.Contains(detail, "403 Forbidden") || !strings.Contains(detail, "Invalid data found") {
		t.Fatalf("converter detail lost the failure cause: %q", detail)
	}
	if strings.ContainsAny(detail, "\n\r") {
		t.Fatalf("converter detail must be a single log line: %q", detail)
	}
}

func TestEncodeSurfacesSanitizedFFmpegFailure(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "not a media container")
	}))
	defer server.Close()
	m := NewManager(Config{FFmpeg: ffmpeg})
	defer m.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, err = m.encode(ctx, cancel, server.URL+"/movie.mkv?sign=capability-token", rangeTimeout, "h264", Compatible, 0, 0, 6, 0, true, nil)
	if err == nil {
		t.Fatal("expected ffmpeg to fail on a non-media source")
	}
	msg := err.Error()
	if !strings.Contains(msg, "playback segment conversion failed") {
		t.Fatalf("conversion failure was not reported: %v", err)
	}
	if strings.Contains(msg, "capability-token") {
		t.Fatalf("signed capability leaked into encoder error: %v", err)
	}
	// The captured stderr must add detail beyond the exit status; without it
	// the original failure was indistinguishable from any other nonzero exit.
	if len(msg) <= len("playback segment conversion failed: exit status 1")+2 {
		t.Fatalf("ffmpeg stderr detail was not captured: %q", msg)
	}
}

func TestStderrTailKeepsRecentOutputBounded(t *testing.T) {
	var tail stderrTail
	for i := 0; i < 5000; i++ {
		fmt.Fprintf(&tail, "warning line %d\n", i)
	}
	if len(tail.buf) > ffmpegStderrLimit {
		t.Fatalf("stderr tail grew to %d bytes", len(tail.buf))
	}
	if !tail.truncated {
		t.Fatal("expected truncation to be reported")
	}
	if !strings.Contains(string(tail.buf), "warning line 4999") {
		t.Fatalf("tail dropped the most recent output: %q", tail.buf)
	}
}

func playbackSessionFixture(m *Manager, id, key string) *Session {
	ctx, cancel := context.WithCancel(m.ctx)
	identity := key
	if n := strings.LastIndexByte(key, 0); n >= 0 {
		identity = key[:n]
	}
	s := &Session{
		ID: id, key: key, identity: identity, sourceURL: "http://127.0.0.1/p/movie.mkv?sign=test&internal_playback=1",
		Index: Index{Duration: 18, Boundaries: []float64{0, 6, 12, 18},
			seekTimes: []float64{0, 9, 15}, VideoCodec: "h264", AudioCodec: "truehd"},
		lastAccess: m.now(), ctx: ctx, cancel: cancel, segments: make(map[segmentKey]*segmentCall),
	}
	m.sessions[id] = s
	m.keys[key] = s
	m.identities[identity] = key
	return s
}

func TestSessionTagIsShortStableAndHidesID(t *testing.T) {
	id := "bearer-capability-id"
	tag := SessionTag(id)
	if len(tag) != 8 || tag != SessionTag(id) || strings.Contains(id, tag) || tag == SessionTag(id+"x") {
		t.Fatalf("SessionTag(%q) = %q", id, tag)
	}
	if got := (&Session{ID: id}).Tag(); got != tag {
		t.Fatalf("Session.Tag() = %q, want %q", got, tag)
	}
}

func TestSessionAccessRefreshesIdleExpiry(t *testing.T) {
	m := NewManager(Config{IdleTimeout: time.Minute})
	defer m.Close()
	now := time.Unix(1000, 0)
	m.now = func() time.Time { return now }
	s := playbackSessionFixture(m, "capability", "user\x00/movie\x001:1")
	m.cacheSegmentLocked(cacheKey{s.ID, segmentKey{Compatible, 0}}, []byte("cached segment"))
	if _, err := m.Get("unknown-capability"); !errors.Is(err, ErrExpired) {
		t.Fatalf("unknown capability returned %v", err)
	}
	now = now.Add(59 * time.Second)
	if _, err := m.Get(s.ID); err != nil {
		t.Fatal(err)
	}
	now = now.Add(59 * time.Second)
	if data, err := m.Segment(context.Background(), s.ID, Compatible, 0); err != nil || string(data) != "cached segment" {
		t.Fatalf("active session lost its segment: %q %v", data, err)
	}
	now = now.Add(time.Minute)
	if _, err := m.Get(s.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("session survived exact idle boundary: %v", err)
	}
	if _, err := m.Segment(context.Background(), s.ID, Compatible, 0); !errors.Is(err, ErrExpired) {
		t.Fatalf("expired capability could access cached media: %v", err)
	}
	if !errors.Is(s.ctx.Err(), context.Canceled) {
		t.Fatal("expiry did not cancel session work")
	}
}
func TestManagerServesCachedSourceWithinSessionLifetime(t *testing.T) {
	data := []byte("0123456789abcdef")
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "movie.mkv", time.Time{}, bytes.NewReader(data))
	}))
	defer origin.Close()
	m := NewManager(Config{
		SourceCacheDir: t.TempDir(), MaxSourceCacheBytes: 16, SourceChunkBytes: 8,
		SourceBaseURL: "http://127.0.0.1/playback",
	})
	entry, err := m.sources.acquire("movie:revision", origin.URL, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	s := playbackSessionFixture(m, "capability", "user\x00/movie\x001:1")
	s.source = entry
	s.sourceURL = "http://127.0.0.1/playback/capability/source"

	req := httptest.NewRequest(http.MethodGet, s.sourceURL, nil)
	req.Header.Set("Range", "bytes=3-11")
	response := httptest.NewRecorder()
	if err := m.Source(response, req, s.ID); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusPartialContent || !bytes.Equal(response.Body.Bytes(), data[3:12]) {
		t.Fatalf("cached source response: status=%d body=%q", response.Code, response.Body.Bytes())
	}
	if entry.record.active != 1 {
		t.Fatalf("request retain leaked: active=%d", entry.record.active)
	}
	m.Close()
	if entry.record.active != 0 {
		t.Fatalf("session close retained source cache: active=%d", entry.record.active)
	}
	if err := m.Source(httptest.NewRecorder(), req, s.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("closed session source returned %v", err)
	}
}

func TestGlobalCacheEvictsLeastRecentlyUsedAllocation(t *testing.T) {
	m := NewManager(Config{MaxCacheBytes: 8, MaxConcurrent: 1})
	defer m.Close()
	a := playbackSessionFixture(m, "a", "user\x00/a\x001:1")
	b := playbackSessionFixture(m, "b", "user\x00/b\x001:1")
	// A four-byte backing allocation counts even when only two bytes are used.
	first := make([]byte, 2, 4)
	copy(first, "aa")
	m.cacheSegmentLocked(cacheKey{a.ID, segmentKey{Compatible, 0}}, first)
	m.cacheSegmentLocked(cacheKey{b.ID, segmentKey{Compatible, 0}}, []byte("bbbb"))
	m.slots <- struct{}{}
	defer func() { <-m.slots }()
	if data, err := m.Segment(context.Background(), a.ID, Compatible, 0); err != nil || string(data) != "aa" {
		t.Fatalf("cache hit was blocked by busy encoder: %q %v", data, err)
	}
	m.cacheSegmentLocked(cacheKey{a.ID, segmentKey{Compatible, 1}}, []byte("cccc"))
	if _, err := m.Segment(context.Background(), b.ID, Compatible, 0); !errors.Is(err, ErrBusy) {
		t.Fatalf("global least-recently-used segment was not evicted: %v", err)
	}
	for n, want := range []string{"aa", "cccc"} {
		if data, err := m.Segment(context.Background(), a.ID, Compatible, n); err != nil || string(data) != want {
			t.Fatalf("recent cache entry %d lost: %q %v", n, data, err)
		}
	}
	if _, err := m.Segment(context.Background(), a.ID, Compatible, -1); err == nil || errors.Is(err, ErrBusy) {
		t.Fatalf("invalid segment was treated as encoder work: %v", err)
	}
	m.Close()
	if _, err := m.Segment(context.Background(), a.ID, Compatible, 0); !errors.Is(err, ErrExpired) {
		t.Fatalf("closed manager exposed cached media: %v", err)
	}
}

func TestNegativeProbeCacheIsBoundedAndRevisionScoped(t *testing.T) {
	var requests atomic.Int32
	data := []byte("not a matroska file")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.ServeContent(w, r, "movie.mkv", time.Time{}, bytes.NewReader(data))
	}))
	defer server.Close()
	m := NewManager(Config{MaxSessions: 2, IdleTimeout: time.Minute})
	defer m.Close()
	now := time.Unix(1000, 0)
	m.now = func() time.Time { return now }
	source := server.URL + "/site/p/movie.mkv?sign=test&internal_playback=1"
	open := func(key string) {
		t.Helper()
		now = now.Add(time.Second)
		if _, err := m.Open(context.Background(), key, source, int64(len(data))); !errors.Is(err, ErrNotNeeded) {
			t.Fatalf("unsupported source returned %v", err)
		}
	}
	open("u\x00/a\x001:1")
	open("u\x00/b\x001:1")
	open("u\x00/a\x001:1")
	if requests.Load() != 2 {
		t.Fatal("repeated unsupported media was probed again")
	}
	open("u\x00/c\x001:1")
	open("u\x00/a\x001:1")
	if requests.Load() != 3 {
		t.Fatal("recent metadata was evicted before older metadata")
	}
	open("u\x00/b\x001:1")
	if requests.Load() != 4 {
		t.Fatal("negative cache exceeded its two-entry limit")
	}
	open("u\x00/b\x001:2")
	if requests.Load() != 5 {
		t.Fatal("changed source revision reused stale negative metadata")
	}
	now = now.Add(time.Minute)
	open("u\x00/b\x001:2")
	if requests.Load() != 6 {
		t.Fatal("negative metadata survived idle expiry")
	}
}

func TestRevisionInvalidationDoesNotCrossUsers(t *testing.T) {
	data := []byte("not a matroska file")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "movie.mkv", time.Time{}, bytes.NewReader(data))
	}))
	defer server.Close()
	m := NewManager(Config{MaxSessions: 2})
	defer m.Close()
	a := playbackSessionFixture(m, "user-a-capability", "a\x00/movie\x001:1")
	b := playbackSessionFixture(m, "user-b-capability", "b\x00/movie\x001:1")
	source := server.URL + "/p/movie?sign=test&internal_playback=1"
	if _, err := m.Open(context.Background(), "a\x00/movie\x001:2", source, int64(len(data))); !errors.Is(err, ErrNotNeeded) {
		t.Fatalf("changed file probe failed: %v", err)
	}
	if _, err := m.Get(a.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("old revision capability survived: %v", err)
	}
	if _, err := m.Get(b.ID); err != nil {
		t.Fatalf("one user's new revision evicted another user's capability: %v", err)
	}
}

// Some WEB-DL releases store VPS/SPS/PPS only in-band: the Matroska hvcC has
// no parameter-set arrays. The init segment must still carry a usable hvcC, or
// every decoder rejects the samples and players show black video with audio.
func TestEncodedHEVCWithInBandParameterSetsHasDecoderConfig(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	source := filepath.Join(t.TempDir(), "source.mkv")
	output, err := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=size=128x72:rate=24",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
		"-t", "16", "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
		"-x265-params", "log-level=error:keyint=48:min-keyint=48:scenecut=0:repeat-headers=1",
		"-c:a", "ac3", source).CombinedOutput()
	if err != nil {
		if strings.Contains(string(output), "libx265") {
			t.Skip("ffmpeg lacks libx265")
		}
		t.Fatalf("generate HEVC source: %v: %s", err, output)
	}
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	clearMatroskaHEVCParameterSets(t, data)
	if err := os.WriteFile(source, data, 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, source)
	}))
	defer server.Close()
	m := NewManager(Config{FFmpeg: ffmpeg})
	defer m.Close()
	session, err := m.Open(ctx, "test\x00hevc\x001", server.URL+"/p/source?sign=test&internal_playback=1", int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Segment(ctx, session.ID, DolbyVision, 1); err == nil {
		t.Fatal("a source without Dolby Vision must not offer the DolbyVision variant")
	}
	// The source has no RPUs to keep, so this checks only the packaging; the
	// variant is enabled the way a profile 5 index would enable it.
	m.mu.Lock()
	m.sessions[session.ID].Index.DolbyVision = &DolbyVisionConfig{Profile: 5, Level: 6, RPU: true, BL: true}
	m.mu.Unlock()
	for _, tc := range []struct {
		variant     Variant
		sampleEntry string
	}{{Compatible, "hev1"}, {DolbyVision, "dvh1"}} {
		segment, err := m.Segment(ctx, session.ID, tc.variant, 1)
		if err != nil {
			t.Fatal(err)
		}
		init, _, ok := splitInit(segment)
		if !ok || !videoDecoderConfigured(init) {
			t.Fatalf("%s init segment hvcC lacks parameter sets", tc.sampleEntry)
		}
		if !bytes.Contains(init, []byte(tc.sampleEntry)) {
			t.Fatalf("variant %d init lacks a %s sample entry", tc.variant, tc.sampleEntry)
		}
		path := filepath.Join(t.TempDir(), "segment.mp4")
		if err := os.WriteFile(path, segment, 0600); err != nil {
			t.Fatal(err)
		}
		frames, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-count_frames", "-select_streams", "v:0",
			"-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", path).Output()
		if n, convErr := strconv.Atoi(strings.TrimSpace(string(frames))); err != nil || convErr != nil || n == 0 {
			t.Fatalf("%s segment video is not decodable: %v: %s", tc.sampleEntry, err, frames)
		}
	}
}

// clearMatroskaHEVCParameterSets rewrites the video CodecPrivate hvcC in place
// to declare zero parameter-set arrays, leaving them only in-band.
func clearMatroskaHEVCParameterSets(t *testing.T, mkv []byte) {
	t.Helper()
	i := bytes.Index(mkv, []byte{0x63, 0xa2}) // CodecPrivate element ID
	if i < 0 || i+2 >= len(mkv) {
		t.Fatal("source has no CodecPrivate")
	}
	width := 1
	for width <= 8 && mkv[i+2]&(0x80>>(width-1)) == 0 {
		width++
	}
	hvcc := i + 2 + width
	if width > 8 || hvcc+23 > len(mkv) || mkv[hvcc] != 1 || mkv[hvcc+22] == 0 {
		t.Fatal("source CodecPrivate is not an hvcC with parameter sets")
	}
	mkv[hvcc+22] = 0 // numOfArrays; the stale array bytes are ignored
}

func TestEncodedSegmentsExcludeSeekPreroll(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	source := filepath.Join(t.TempDir(), "source.mkv")
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=size=128x72:rate=24",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
		"-t", "32", "-c:v", "libx264", "-preset", "ultrafast",
		"-g", "120", "-keyint_min", "120", "-sc_threshold", "0", "-bf", "2",
		"-c:a", "ac3", source)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate seekable source: %v: %s", err, output)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, source)
	}))
	defer server.Close()
	m := NewManager(Config{FFmpeg: ffmpeg})
	defer m.Close()
	info, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	session, err := m.Open(ctx, "test\x00source\x001", server.URL+"/p/source?sign=test&internal_playback=1", info.Size())
	if err != nil {
		t.Fatal(err)
	}
	// Exercise adjacent middle intervals and the final short GOP at EOF.
	inits := map[int][]byte{}
	for _, n := range []int{1, 2, 3} {
		start := session.Index.Boundaries[n]
		end := min(session.Index.Boundaries[n+1], 32)
		t.Run(seconds(start), func(t *testing.T) {
			data, err := m.Segment(ctx, session.ID, Compatible, n)
			if err != nil {
				t.Fatal(err)
			}
			// Players read EXT-X-MAP once and then fetch media-only fragments;
			// each segment must split cleanly into a shared init and its media.
			init, media, ok := splitInit(data)
			if !ok {
				t.Fatal("encoded segment is missing its init or media run")
			}
			if len(init) < 8 || string(init[4:8]) != "ftyp" {
				t.Fatal("init run must start with an ftyp box")
			}
			if len(media) < 8 || string(media[4:8]) != "moof" {
				t.Fatal("media run must start with a moof box")
			}
			// A per-segment reset to 1 makes VLC 4 treat every fragment after
			// the first as a passive seek; the sequence must advance globally.
			if seqs := fragmentSequences(data); len(seqs) != 1 || seqs[0] != uint32(n)+1 {
				t.Fatalf("segment %d fragment sequence = %v, want [%d]", n, seqs, n+1)
			}
			inits[n] = append([]byte(nil), init...)
			segment := filepath.Join(t.TempDir(), "segment.mp4")
			if err := os.WriteFile(segment, data, 0600); err != nil {
				t.Fatal(err)
			}
			output, err := exec.CommandContext(ctx, ffprobe, "-v", "error",
				"-show_packets", "-show_entries", "packet=stream_index,pts_time,duration_time,flags",
				"-of", "json", segment).Output()
			if err != nil {
				t.Fatal(err)
			}
			var probe struct {
				Packets []struct {
					Stream   int    `json:"stream_index"`
					PTS      string `json:"pts_time"`
					Duration string `json:"duration_time"`
					Flags    string `json:"flags"`
				} `json:"packets"`
			}
			if err := json.Unmarshal(output, &probe); err != nil {
				t.Fatal(err)
			}
			// Audio is placed after the grid by the video's reorder delay less
			// AAC priming, so both reach the viewer equally late.
			audioShift := math.NaN()
			for _, packet := range probe.Packets {
				if packet.Stream == 0 && strings.Contains(packet.Flags, "K") {
					pts, _ := strconv.ParseFloat(packet.PTS, 64)
					audioShift = math.Max(0, math.Round((pts-start)*48000)-aacPrimingSamples) / 48000
					break
				}
			}
			if math.IsNaN(audioShift) {
				t.Fatal("segment has no keyframe")
			}
			// AAC frames are whole 1024-sample units on a global grid.
			// A fractional final packet only *claims* to end at EXTINF;
			// decoders still output its full 1024 samples and drift on VOD.
			var streams struct {
				Streams []struct {
					Index    int    `json:"index"`
					Duration string `json:"duration"`
				} `json:"streams"`
			}
			streamJSON, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-show_entries", "stream=index,duration", "-of", "json", segment).Output()
			if err != nil || json.Unmarshal(streamJSON, &streams) != nil {
				t.Fatalf("probe encoded streams: %v %s", err, streamJSON)
			}
			for _, stream := range streams.Streams {
				if stream.Index != 1 {
					continue
				}
				audioEnd, err := strconv.ParseFloat(stream.Duration, 64)
				wantEnd := math.Round(end*48000/1024)*1024/48000 + audioShift
				if err != nil || math.Abs(audioEnd-wantEnd) > 0.001 {
					t.Fatalf("audio end %s != global AAC boundary %.6f", stream.Duration, wantEnd)
				}
			}
			frames, audioFrames := 0, 0
			for _, packet := range probe.Packets {
				if packet.Stream == 1 {
					d, err := strconv.ParseFloat(packet.Duration, 64)
					if err != nil || math.Abs(d-1024.0/48000) > 0.00001 {
						t.Fatalf("AAC packet %d has partial duration %s", audioFrames, packet.Duration)
					}
					if audioFrames == 0 {
						pts, err := strconv.ParseFloat(packet.PTS, 64)
						want := math.Round(start*48000/1024)*1024/48000 + audioShift
						if err != nil || math.Abs(pts-want) > 0.001 {
							t.Fatalf("AAC begins at %s instead of %.6f", packet.PTS, want)
						}
					}
					audioFrames++
					continue
				}
				if packet.Stream != 0 {
					continue
				}
				pts, err := strconv.ParseFloat(packet.PTS, 64)
				if err != nil || pts < start || pts >= end+0.1 {
					t.Fatalf("video sample outside interval: pts=%s start=%v", packet.PTS, start)
				}
				if frames == 0 && !strings.Contains(packet.Flags, "K") {
					t.Fatal("segment must start with an independently decodable frame")
				}
				frames++
			}
			wantAudio := int(math.Round(end*48000/1024) - math.Round(start*48000/1024))
			if audioFrames != wantAudio {
				t.Fatalf("interval has %d AAC frames, want %d", audioFrames, wantAudio)
			}
			wantFrames := int(math.Round((end - start) * 24))
			if frames != wantFrames {
				t.Fatalf("interval contains %d frames, want %d (no seek preroll or next segment)", frames, wantFrames)
			}
			// Matching decoded frames also rejects a correctly sized segment
			// that accidentally copies the preceding GOP instead of this one.
			hash := func(input string, filter string) string {
				t.Helper()
				args := []string{"-v", "error", "-i", input, "-map", "0:v:0"}
				if filter != "" {
					args = append(args, "-vf", filter)
				}
				args = append(args, "-fps_mode", "passthrough", "-f", "hash", "-hash", "sha256", "-")
				out, err := exec.CommandContext(ctx, ffmpeg, args...).CombinedOutput()
				if err != nil {
					t.Fatalf("decode segment: %v: %s", err, out)
				}
				return string(out)
			}
			expected := hash(source, fmt.Sprintf("trim=start_frame=%d:end_frame=%d", int(start)*24, int(end)*24))
			if got := hash(segment, ""); got != expected {
				t.Fatal("segment decoded frames differ from the indexed source interval")
			}
		})
	}
	if len(inits) == 3 && (!bytes.Equal(inits[1], inits[2]) || !bytes.Equal(inits[1], inits[3])) {
		t.Fatal("segments must share one initialization segment")
	}
	init, err := m.Init(ctx, session.ID, Compatible)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(init, inits[1]) {
		t.Fatal("Manager.Init did not return the shared initialization segment")
	}
}

// VLC 4 reads tfdt only after a discontinuity and otherwise accumulates trun
// sample durations, so every segment's video must tile its playlist slot
// exactly: no frame repeated across a boundary and no duration shortfall.
// A 23.976 fps source with 161-frame GOPs gives fractional millisecond
// boundaries whose float differences previously kept the next segment's
// keyframe, drifting video ~42 ms later per affected segment.
func TestAdjacentSegmentsTileVideoTimeline(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	source := filepath.Join(t.TempDir(), "source.mkv")
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=size=128x72:rate=24000/1001",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
		"-t", "75", "-c:v", "libx264", "-preset", "ultrafast",
		"-g", "161", "-keyint_min", "161", "-sc_threshold", "0", "-bf", "2",
		"-c:a", "ac3", source)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate 23.976 fps source: %v: %s", err, output)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, source)
	}))
	defer server.Close()
	m := NewManager(Config{FFmpeg: ffmpeg})
	defer m.Close()
	info, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	session, err := m.Open(ctx, "test\x00tile\x001", server.URL+"/p/source?sign=test&internal_playback=1", info.Size())
	if err != nil {
		t.Fatal(err)
	}
	boundaries := session.Index.Boundaries
	if len(boundaries) < 8 {
		t.Fatalf("index has %d boundaries, want several fractional GOP boundaries", len(boundaries))
	}
	seen := map[int64]int{}
	frames := 0
	// The final interval ends at the container duration rather than a
	// keyframe, so only full keyframe-to-keyframe slots must tile exactly.
	for n := 0; n < len(boundaries)-2; n++ {
		data, err := m.Segment(ctx, session.ID, Compatible, n)
		if err != nil {
			t.Fatalf("segment %d: %v", n, err)
		}
		segment := filepath.Join(t.TempDir(), "segment.mp4")
		if err := os.WriteFile(segment, data, 0600); err != nil {
			t.Fatal(err)
		}
		output, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=time_base:packet=pts,dts,duration", "-of", "json", segment).Output()
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Streams []struct {
				TimeBase string `json:"time_base"`
			} `json:"streams"`
			Packets []struct {
				PTS      int64 `json:"pts"`
				DTS      int64 `json:"dts"`
				Duration int64 `json:"duration"`
			} `json:"packets"`
		}
		if err := json.Unmarshal(output, &probe); err != nil || len(probe.Streams) != 1 || len(probe.Packets) == 0 {
			t.Fatalf("probe segment %d: %v %s", n, err, output)
		}
		var timescale int64
		if _, err := fmt.Sscanf(probe.Streams[0].TimeBase, "1/%d", &timescale); err != nil || timescale <= 0 {
			t.Fatalf("segment %d video time base %q", n, probe.Streams[0].TimeBase)
		}
		var sum int64
		for _, packet := range probe.Packets {
			if previous, ok := seen[packet.PTS]; ok {
				t.Fatalf("video pts %d appears in segments %d and %d", packet.PTS, previous, n)
			}
			seen[packet.PTS] = n
			sum += packet.Duration
		}
		frames += len(probe.Packets)
		slot := int64(math.Round(boundaries[n+1]*float64(timescale))) - int64(math.Round(boundaries[n]*float64(timescale)))
		if sum != slot {
			t.Fatalf("segment %d video durations sum to %d ticks, slot %.6f-%.6f is %d (1/%d)",
				n, sum, boundaries[n], boundaries[n+1], slot, timescale)
		}
		if first := probe.Packets[0].DTS; first != int64(math.Round(boundaries[n]*float64(timescale))) {
			t.Fatalf("segment %d video starts at dts %d, want %d", n, first, int64(math.Round(boundaries[n]*float64(timescale))))
		}
	}
	if want := (len(boundaries) - 2) * 161; frames != want {
		t.Fatalf("segments contain %d video frames, want %d", frames, want)
	}
}

// Stream-copied B-frame video is presented one reorder delay (the first
// sample's composition offset) after the source, while re-encoded AAC only
// trails by its 1024-sample priming. Audio must carry the same delay as the
// video so lips and speech line up: measure both against the source.
func TestAudioContentMatchesVideoPresentation(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	dir := t.TempDir()
	source := filepath.Join(dir, "source.mkv")
	// A 20 ms 1 kHz beep at every k+0.5 s gives unambiguous audio onsets.
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc2=size=128x72:rate=24",
		"-f", "lavfi", "-i", `aevalsrc=exprs=if(lt(mod(t+0.5\,1)\,0.02)\,0.8*sin(2*PI*1000*t)\,0):s=48000`,
		"-t", "21", "-c:v", "libx264", "-preset", "ultrafast",
		"-g", "120", "-keyint_min", "120", "-sc_threshold", "0", "-bf", "2",
		"-c:a", "ac3", source)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate beeping source: %v: %s", err, output)
	}
	// onsets decodes a file's first audio stream and returns each beep's start
	// in seconds on that stream's own timeline.
	onsets := func(path string) []float64 {
		t.Helper()
		out, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-select_streams", "a:0",
			"-show_entries", "packet=pts_time", "-read_intervals", "%+#1", "-of", "csv=p=0", path).Output()
		first, perr := strconv.ParseFloat(strings.Trim(strings.Split(string(out), "\n")[0], " ,\r"), 64)
		if err != nil || perr != nil {
			t.Fatalf("probe audio start of %s: %v %v %q", path, err, perr, out)
		}
		pcm, err := exec.CommandContext(ctx, ffmpeg, "-v", "error", "-i", path, "-map", "0:a:0",
			"-ac", "1", "-ar", "48000", "-f", "s16le", "-").Output()
		if err != nil {
			t.Fatalf("decode audio of %s: %v", path, err)
		}
		var found []float64
		quiet := 0
		for i := 0; i+1 < len(pcm); i += 2 {
			v := int16(binary.LittleEndian.Uint16(pcm[i:]))
			if v > 4000 || v < -4000 {
				if quiet > 4800 || len(found) == 0 && quiet == i/2 {
					found = append(found, first+float64(i/2)/48000)
				}
				quiet = 0
				continue
			}
			quiet++
		}
		return found
	}
	sourceOnsets := onsets(source)
	if len(sourceOnsets) < 15 {
		t.Fatalf("source has %d beeps", len(sourceOnsets))
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, source)
	}))
	defer server.Close()
	m := NewManager(Config{FFmpeg: ffmpeg})
	defer m.Close()
	info, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	session, err := m.Open(ctx, "test\x00lipsync\x001", server.URL+"/p/source?sign=test&internal_playback=1", info.Size())
	if err != nil {
		t.Fatal(err)
	}
	for n := 0; n < len(session.Index.Boundaries)-2; n++ {
		start := session.Index.Boundaries[n]
		data, err := m.Segment(ctx, session.ID, Compatible, n)
		if err != nil {
			t.Fatal(err)
		}
		segment := filepath.Join(dir, fmt.Sprintf("segment-%d.mp4", n))
		if err := os.WriteFile(segment, data, 0600); err != nil {
			t.Fatal(err)
		}
		out, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-select_streams", "v:0",
			"-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", segment).Output()
		if err != nil {
			t.Fatal(err)
		}
		// The keyframe opening the slot is the source frame at start.
		videoDelay := math.NaN()
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			fields := strings.Split(line, ",")
			if len(fields) >= 2 && strings.Contains(fields[1], "K") {
				pts, _ := strconv.ParseFloat(fields[0], 64)
				videoDelay = pts - start
				break
			}
		}
		if math.IsNaN(videoDelay) || videoDelay < 0.04 {
			t.Fatalf("segment %d: B-frame video should be presented after its slot start, delay %.4f", n, videoDelay)
		}
		beeps := onsets(segment)
		if len(beeps) == 0 {
			t.Fatalf("segment %d has no beep", n)
		}
		for _, beep := range beeps {
			nearest := sourceOnsets[0]
			for _, s := range sourceOnsets {
				if math.Abs(beep-videoDelay-s) < math.Abs(beep-videoDelay-nearest) {
					nearest = s
				}
			}
			// Segment audio sits on a global 1024-sample grid, so its content
			// may lead or trail the slot by up to half an AAC frame (10.7 ms).
			if audioDelay := beep - nearest; math.Abs(audioDelay-videoDelay) > 0.012 {
				t.Fatalf("segment %d: audio trails the source by %.1f ms but video by %.1f ms",
					n, audioDelay*1000, videoDelay*1000)
			}
		}
	}
}

// WEB-DL remuxes often start video one B-frame reorder delay after audio, so
// the first interval's video covers less than its slot, which opens at 0.
// That lead must survive as a later decode time, not count as a lost frame or
// present the first interval early.
func TestFirstSegmentKeepsLateVideoStart(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	dir := t.TempDir()
	source := filepath.Join(dir, "source.mkv")
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error",
		"-itsoffset", "0.084", "-f", "lavfi", "-i", "testsrc2=size=128x72:rate=60000/1001",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
		"-t", "30", "-c:v", "libx264", "-preset", "ultrafast",
		"-g", "300", "-keyint_min", "300", "-sc_threshold", "0", "-bf", "2",
		"-c:a", "ac3", source)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate late-video source: %v: %s", err, output)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, source)
	}))
	defer server.Close()
	m := NewManager(Config{FFmpeg: ffmpeg})
	defer m.Close()
	info, err := os.Stat(source)
	if err != nil {
		t.Fatal(err)
	}
	session, err := m.Open(ctx, "test\x00lead\x001", server.URL+"/p/source?sign=test&internal_playback=1", info.Size())
	if err != nil {
		t.Fatal(err)
	}
	boundaries := session.Index.Boundaries
	if lead := 0.0834; lead < 0.08 || lead > 0.09 || len(boundaries) < 4 {
		t.Fatalf("first keyframe at %.4f with boundaries %v, want about 0.084 and several slots", lead, boundaries)
	}
	// keyframeDelay returns how long after its source time each segment's
	// opening keyframe is presented, and checks the video fills its slot.
	keyframeDelay := func(n int, sourceTime float64) float64 {
		t.Helper()
		data, err := m.Segment(ctx, session.ID, Compatible, n)
		if err != nil {
			t.Fatalf("segment %d: %v", n, err)
		}
		segment := filepath.Join(dir, fmt.Sprintf("segment-%d.mp4", n))
		if err := os.WriteFile(segment, data, 0600); err != nil {
			t.Fatal(err)
		}
		output, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=time_base:packet=pts,dts,duration", "-of", "json", segment).Output()
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Streams []struct {
				TimeBase string `json:"time_base"`
			} `json:"streams"`
			Packets []struct {
				PTS      int64 `json:"pts"`
				DTS      int64 `json:"dts"`
				Duration int64 `json:"duration"`
			} `json:"packets"`
		}
		var timescale int64
		if err := json.Unmarshal(output, &probe); err != nil || len(probe.Streams) != 1 || len(probe.Packets) == 0 {
			t.Fatalf("probe segment %d: %v %s", n, err, output)
		}
		if _, err := fmt.Sscanf(probe.Streams[0].TimeBase, "1/%d", &timescale); err != nil || timescale <= 0 {
			t.Fatalf("segment %d video time base %q", n, probe.Streams[0].TimeBase)
		}
		end := probe.Packets[0].DTS
		for _, packet := range probe.Packets {
			end += packet.Duration
		}
		if want := int64(math.Round(boundaries[n+1] * float64(timescale))); end != want {
			t.Fatalf("segment %d video ends at %d ticks, slot ends at %d (1/%d)", n, end, want, timescale)
		}
		return float64(probe.Packets[0].PTS)/float64(timescale) - sourceTime
	}
	first := keyframeDelay(0, session.Index.firstKeyframe)
	second := keyframeDelay(1, boundaries[1])
	if math.Abs(first-second) > 0.001 {
		t.Fatalf("first segment's video is presented %.1f ms after the source, later ones %.1f ms",
			first*1000, second*1000)
	}
}
