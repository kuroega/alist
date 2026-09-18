package playback

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSourceCacheCoalescesRangesAndSurvivesRestart(t *testing.T) {
	data := []byte("abcdefghijklmnopqrstuvwxyz")
	var requests atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		time.Sleep(20 * time.Millisecond)
		http.ServeContent(w, r, "source.mkv", time.Time{}, bytes.NewReader(data))
	}))
	cacheDir := t.TempDir()
	store, err := newSourceStore(cacheDir, 64, 8, origin.Client())
	if err != nil {
		t.Fatal(err)
	}
	entry, err := store.acquire("movie:revision", origin.URL, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}

	start := make(chan struct{})
	results := make(chan error, 2)
	for range 2 {
		go func() {
			<-start
			got := make([]byte, 4)
			_, err := entry.ReadAt(context.Background(), got, 2)
			if err == nil && !bytes.Equal(got, data[2:6]) {
				err = fmt.Errorf("got %q", got)
			}
			results <- err
		}()
	}
	close(start)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("concurrent cache miss made %d source requests, want 1", got)
	}

	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/source", nil)
	req.Header.Set("Range", "bytes=6-13")
	response := httptest.NewRecorder()
	if err := entry.serve(response, req); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusPartialContent || response.Header().Get("Content-Range") != "bytes 6-13/26" ||
		!bytes.Equal(response.Body.Bytes(), data[6:14]) {
		t.Fatalf("invalid cached range: status=%d range=%q body=%q", response.Code, response.Header().Get("Content-Range"), response.Body.Bytes())
	}
	if got := requests.Load(); got != 2 {
		t.Fatalf("cross-chunk range made %d source requests, want 2", got)
	}
	store.release(entry)
	origin.Close()

	restarted, err := newSourceStore(cacheDir, 64, 8, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	persisted, err := restarted.acquire("movie:revision", "http://127.0.0.1:1/unreachable", int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 16)
	if _, err := persisted.ReadAt(context.Background(), got, 0); err != nil || !bytes.Equal(got, data[:16]) {
		t.Fatalf("persisted cache read: %q %v", got, err)
	}
	restarted.release(persisted)
}

func TestSourceCacheRejectsTruncatedChunk(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Range", "bytes 0-7/8")
		w.Header().Set("Content-Length", "8")
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.WriteString(w, "short")
	}))
	defer origin.Close()
	store, err := newSourceStore(t.TempDir(), 8, 8, origin.Client())
	if err != nil {
		t.Fatal(err)
	}
	entry, err := store.acquire("movie", origin.URL, 8)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.ReadAt(context.Background(), make([]byte, 1), 0); !errors.Is(err, errRange) {
		t.Fatalf("truncated source returned %v", err)
	}
	if entry.record.bytes != 0 || store.usedBytes != 0 {
		t.Fatal("truncated chunk consumed cache capacity")
	}
	store.release(entry)
}

func TestSourceCacheEvictsInactiveRevision(t *testing.T) {
	data := bytes.Repeat([]byte("x"), 16)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "source.mkv", time.Time{}, bytes.NewReader(data))
	}))
	defer origin.Close()
	store, err := newSourceStore(t.TempDir(), 16, 8, origin.Client())
	if err != nil {
		t.Fatal(err)
	}
	old, err := store.acquire("old", origin.URL, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := old.ReadAt(context.Background(), make([]byte, 8), 0); err != nil {
		t.Fatal(err)
	}
	oldDir := old.record.dir
	store.release(old)

	current, err := store.acquire("current", origin.URL, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	for _, offset := range []int64{0, 8} {
		if _, err := current.ReadAt(context.Background(), make([]byte, 8), offset); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(oldDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("inactive revision was not evicted: %v", err)
	}
	if store.usedBytes > store.maxBytes {
		t.Fatalf("cache used %d bytes over %d-byte limit", store.usedBytes, store.maxBytes)
	}
	store.release(current)
}

func TestSourceCacheRemovesCorruptMetadata(t *testing.T) {
	root := t.TempDir()
	id := strings.Repeat("a", sha256.Size*2)
	dir := filepath.Join(root, id)
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "metadata.json"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, chunkName(0)), []byte("stale"), 0600); err != nil {
		t.Fatal(err)
	}

	store, err := newSourceStore(root, 16, 8, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	if store.usedBytes != 0 {
		t.Fatalf("corrupt entry consumed %d cache bytes", store.usedBytes)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("corrupt cache entry was not removed: %v", err)
	}
}
