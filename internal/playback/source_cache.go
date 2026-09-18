package playback

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alist-org/alist/v3/pkg/http_range"
)

const (
	sourceCacheVersion      = 1
	sourceChunkTimeout      = time.Minute
	sourcePrefetchThreshold = 2 << 20
)

var errSourceCacheFull = errors.New("playback source cache is full")

type sourceCacheMetadata struct {
	Version   int   `json:"version"`
	Size      int64 `json:"size"`
	ChunkSize int64 `json:"chunk_size"`
}

type sourceCacheRecord struct {
	id         string
	dir        string
	size       int64
	bytes      int64
	lastAccess time.Time
	active     int
	entry      *sourceEntry
}

type sourceStore struct {
	mu         sync.Mutex
	root       string
	maxBytes   int64
	chunkBytes int64
	client     *http.Client
	records    map[string]*sourceCacheRecord
	usedBytes  int64
}

type sourceEntry struct {
	store  *sourceStore
	record *sourceCacheRecord

	mu        sync.Mutex
	sourceURL string
	ready     map[int64]string
	calls     map[int64]*sourceChunkCall
}

type sourceChunkCall struct {
	done chan struct{}
	path string
	err  error
}

type sourceStream struct {
	ctx        context.Context
	entry      *sourceEntry
	offset     int64
	remaining  int64
	read       int64
	file       *os.File
	fileChunk  int64
	prefetched int64
}

func newSourceStore(root string, maxBytes, chunkBytes int64, client *http.Client) (*sourceStore, error) {
	if maxBytes <= 0 || chunkBytes <= 0 {
		return nil, nil
	}
	if root == "" {
		return nil, errors.New("playback source cache directory is empty")
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, errors.New("could not resolve playback source cache directory")
	}
	if err := os.MkdirAll(absolute, 0700); err != nil {
		return nil, errors.New("could not create playback source cache directory")
	}
	if err := os.Chmod(absolute, 0700); err != nil {
		return nil, errors.New("could not secure playback source cache directory")
	}
	store := &sourceStore{
		root: absolute, maxBytes: maxBytes, chunkBytes: chunkBytes,
		client: client, records: make(map[string]*sourceCacheRecord),
	}
	if err := store.scan(); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *sourceStore) scan() error {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return errors.New("could not scan playback source cache")
	}
	for _, item := range entries {
		if !item.IsDir() || !validCacheID(item.Name()) {
			continue
		}
		dir := filepath.Join(s.root, item.Name())
		metadata, err := readSourceCacheMetadata(dir)
		if err != nil {
			if err := os.RemoveAll(dir); err != nil {
				return errors.New("could not remove corrupt playback source cache")
			}
			continue
		}
		if metadata.Version != sourceCacheVersion || metadata.Size <= 0 || metadata.ChunkSize != s.chunkBytes {
			if err := os.RemoveAll(dir); err != nil {
				return errors.New("could not remove incompatible playback source cache")
			}
			continue
		}
		info, err := item.Info()
		if err != nil {
			return errors.New("could not inspect playback source cache")
		}
		record := &sourceCacheRecord{
			id: item.Name(), dir: dir, size: metadata.Size, lastAccess: info.ModTime(),
		}
		files, err := os.ReadDir(dir)
		if err != nil {
			return errors.New("could not scan playback source cache entry")
		}
		for _, file := range files {
			if strings.HasPrefix(file.Name(), ".chunk-") {
				_ = os.Remove(filepath.Join(dir, file.Name()))
				continue
			}
			index, ok := parseChunkName(file.Name())
			if !ok || file.IsDir() {
				continue
			}
			stat, err := file.Info()
			if err != nil {
				return errors.New("could not inspect playback source cache chunk")
			}
			if stat.Size() != record.chunkLength(index, s.chunkBytes) {
				if err := os.Remove(filepath.Join(dir, file.Name())); err != nil {
					return errors.New("could not remove invalid playback source cache chunk")
				}
				continue
			}
			record.bytes += stat.Size()
		}
		s.records[record.id] = record
		s.usedBytes += record.bytes
	}
	for s.usedBytes > s.maxBytes {
		oldest := s.oldestEvictableLocked("")
		if oldest == nil {
			break
		}
		if err := s.removeRecordLocked(oldest); err != nil {
			return err
		}
	}
	return nil
}

func validCacheID(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func readSourceCacheMetadata(dir string) (sourceCacheMetadata, error) {
	var metadata sourceCacheMetadata
	data, err := os.ReadFile(filepath.Join(dir, "metadata.json"))
	if err != nil {
		return metadata, err
	}
	if err := json.Unmarshal(data, &metadata); err != nil {
		return metadata, err
	}
	return metadata, nil
}

func (r *sourceCacheRecord) chunkLength(index, chunkBytes int64) int64 {
	start := index * chunkBytes
	if start < 0 || start >= r.size {
		return 0
	}
	return min(chunkBytes, r.size-start)
}

func chunkName(index int64) string {
	return fmt.Sprintf("chunk-%016x", index)
}

func parseChunkName(name string) (int64, bool) {
	const prefix = "chunk-"
	if !strings.HasPrefix(name, prefix) || len(name) != len(prefix)+16 {
		return 0, false
	}
	value, err := strconv.ParseInt(name[len(prefix):], 16, 64)
	return value, err == nil && value >= 0
}

func (s *sourceStore) acquire(key, sourceURL string, size int64) (*sourceEntry, error) {
	if size <= 0 || size > s.maxBytes {
		return nil, nil
	}
	digest := sha256.Sum256([]byte(key))
	id := hex.EncodeToString(digest[:])

	s.mu.Lock()
	record := s.records[id]
	if record == nil {
		dir := filepath.Join(s.root, id)
		if err := os.MkdirAll(dir, 0700); err != nil {
			s.mu.Unlock()
			return nil, errors.New("could not create playback source cache entry")
		}
		metadata, err := json.Marshal(sourceCacheMetadata{Version: sourceCacheVersion, Size: size, ChunkSize: s.chunkBytes})
		if err != nil {
			s.mu.Unlock()
			return nil, errors.New("could not encode playback source cache metadata")
		}
		if err := os.WriteFile(filepath.Join(dir, "metadata.json"), metadata, 0600); err != nil {
			s.mu.Unlock()
			return nil, errors.New("could not write playback source cache metadata")
		}
		record = &sourceCacheRecord{id: id, dir: dir, size: size, lastAccess: time.Now()}
		s.records[id] = record
	} else if record.size != size {
		s.mu.Unlock()
		return nil, errors.New("playback source cache revision mismatch")
	}
	if record.entry == nil {
		record.entry = &sourceEntry{
			store: s, record: record, ready: make(map[int64]string), calls: make(map[int64]*sourceChunkCall),
		}
	}
	record.active++
	record.lastAccess = time.Now()
	entry := record.entry
	s.mu.Unlock()

	entry.mu.Lock()
	entry.sourceURL = sourceURL
	entry.mu.Unlock()
	return entry, nil
}

func (s *sourceStore) retain(entry *sourceEntry) {
	s.mu.Lock()
	entry.record.active++
	entry.record.lastAccess = time.Now()
	s.mu.Unlock()
}

func (s *sourceStore) release(entry *sourceEntry) {
	if entry == nil {
		return
	}
	s.mu.Lock()
	if entry.record.active > 0 {
		entry.record.active--
	}
	entry.record.lastAccess = time.Now()
	lastAccess := entry.record.lastAccess
	dir := entry.record.dir
	s.mu.Unlock()
	_ = os.Chtimes(dir, lastAccess, lastAccess)
}

func (s *sourceStore) reserve(record *sourceCacheRecord, bytes int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for s.usedBytes+bytes > s.maxBytes {
		oldest := s.oldestEvictableLocked(record.id)
		if oldest == nil {
			return errSourceCacheFull
		}
		if err := s.removeRecordLocked(oldest); err != nil {
			return err
		}
	}
	s.usedBytes += bytes
	record.bytes += bytes
	record.lastAccess = time.Now()
	return nil
}

func (s *sourceStore) unreserve(record *sourceCacheRecord, bytes int64) {
	s.mu.Lock()
	s.usedBytes -= bytes
	record.bytes -= bytes
	s.mu.Unlock()
}

func (s *sourceStore) discard(record *sourceCacheRecord, bytes int64) {
	if bytes <= 0 {
		return
	}
	s.mu.Lock()
	s.usedBytes = max(0, s.usedBytes-bytes)
	record.bytes = max(0, record.bytes-bytes)
	s.mu.Unlock()
}

func (s *sourceStore) oldestEvictableLocked(exclude string) *sourceCacheRecord {
	var oldest *sourceCacheRecord
	for id, record := range s.records {
		if id == exclude || record.active != 0 {
			continue
		}
		if oldest == nil || record.lastAccess.Before(oldest.lastAccess) {
			oldest = record
		}
	}
	return oldest
}

func (s *sourceStore) removeRecordLocked(record *sourceCacheRecord) error {
	if err := os.RemoveAll(record.dir); err != nil {
		return errors.New("could not evict playback source cache entry")
	}
	delete(s.records, record.id)
	s.usedBytes -= record.bytes
	return nil
}

func (e *sourceEntry) ReadAt(ctx context.Context, p []byte, off int64) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if off < 0 {
		return 0, errors.New("invalid playback source offset")
	}
	if off >= e.record.size {
		return 0, io.EOF
	}
	length := min(int64(len(p)), e.record.size-off)
	total := 0
	for int64(total) < length {
		index := (off + int64(total)) / e.store.chunkBytes
		path, err := e.ensureChunk(ctx, index)
		if err != nil {
			return total, err
		}
		file, err := os.Open(path)
		if err != nil {
			return total, errors.New("could not open playback source cache chunk")
		}
		within := (off + int64(total)) % e.store.chunkBytes
		count := min(length-int64(total), e.record.chunkLength(index, e.store.chunkBytes)-within)
		n, readErr := file.ReadAt(p[total:total+int(count)], within)
		_ = file.Close()
		total += n
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return total, errors.New("could not read playback source cache chunk")
		}
		if int64(n) != count {
			return total, errRange
		}
	}
	if int64(total) < int64(len(p)) {
		return total, io.EOF
	}
	return total, nil
}

func (e *sourceEntry) ensureChunk(ctx context.Context, index int64) (string, error) {
	if e.record.chunkLength(index, e.store.chunkBytes) <= 0 {
		return "", io.EOF
	}
	e.mu.Lock()
	if path := e.ready[index]; path != "" {
		e.mu.Unlock()
		return path, nil
	}
	path := filepath.Join(e.record.dir, chunkName(index))
	if info, err := os.Stat(path); err == nil && info.Size() == e.record.chunkLength(index, e.store.chunkBytes) {
		e.ready[index] = path
		e.mu.Unlock()
		return path, nil
	} else if err == nil {
		_ = os.Remove(path)
		e.store.discard(e.record, info.Size())
	}
	if call := e.calls[index]; call != nil {
		e.mu.Unlock()
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-call.done:
			return call.path, call.err
		}
	}
	call := &sourceChunkCall{done: make(chan struct{})}
	e.calls[index] = call
	e.mu.Unlock()

	call.err = e.fetchChunk(ctx, index, path)
	if call.err == nil {
		call.path = path
	}

	e.mu.Lock()
	delete(e.calls, index)
	if call.err == nil {
		e.ready[index] = call.path
	}
	close(call.done)
	e.mu.Unlock()
	return call.path, call.err
}
func (e *sourceEntry) setSourceURL(sourceURL string) {
	e.mu.Lock()
	e.sourceURL = sourceURL
	e.mu.Unlock()
}

func (e *sourceEntry) fetchChunk(parent context.Context, index int64, destination string) error {
	length := e.record.chunkLength(index, e.store.chunkBytes)
	start := index * e.store.chunkBytes
	e.mu.Lock()
	sourceURL := e.sourceURL
	e.mu.Unlock()
	if sourceURL == "" {
		return errSource
	}
	ctx, cancel := context.WithTimeout(parent, sourceChunkTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return errSource
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, start+length-1))
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := e.store.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return errSource
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent ||
		resp.Header.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", start, start+length-1, e.record.size) ||
		(resp.ContentLength >= 0 && resp.ContentLength != length) ||
		(resp.Header.Get("Content-Encoding") != "" && resp.Header.Get("Content-Encoding") != "identity") {
		return errRange
	}
	temp, err := os.CreateTemp(e.record.dir, ".chunk-")
	if err != nil {
		return errors.New("could not create playback source cache chunk")
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0600); err != nil {
		_ = temp.Close()
		return errors.New("could not secure playback source cache chunk")
	}
	written, copyErr := io.CopyN(temp, resp.Body, length)
	if copyErr == nil {
		var extra [1]byte
		if n, readErr := resp.Body.Read(extra[:]); n != 0 || readErr != io.EOF {
			copyErr = errRange
		}
	}
	if copyErr == nil && written != length {
		copyErr = errRange
	}
	if copyErr == nil {
		copyErr = temp.Sync()
	}
	if closeErr := temp.Close(); copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return errRange
	}
	if err := e.store.reserve(e.record, length); err != nil {
		return err
	}
	if err := os.Rename(tempName, destination); err != nil {
		e.store.unreserve(e.record, length)
		return errors.New("could not commit playback source cache chunk")
	}
	return nil
}

func (e *sourceEntry) prefetch(ctx context.Context, index int64) {
	if e.record.chunkLength(index, e.store.chunkBytes) <= 0 {
		return
	}
	go func() {
		_, _ = e.ensureChunk(ctx, index)
	}()
}

func (e *sourceEntry) serve(w http.ResponseWriter, r *http.Request) error {
	ranges, err := http_range.ParseRange(r.Header.Get("Range"), e.record.size)
	if err != nil || len(ranges) > 1 {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", e.record.size))
		w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		return nil
	}
	start, length, status := int64(0), e.record.size, http.StatusOK
	if len(ranges) == 1 {
		start, length, status = ranges[0].Start, ranges[0].Length, http.StatusPartialContent
		w.Header().Set("Content-Range", ranges[0].ContentRange(e.record.size))
	}
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "private, no-store")
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return nil
	}
	stream := &sourceStream{
		ctx: r.Context(), entry: e, offset: start, remaining: length,
		fileChunk: -1, prefetched: -1,
	}
	defer stream.Close()
	written, err := io.CopyN(w, stream, length)
	if err != nil {
		if r.Context().Err() != nil {
			return r.Context().Err()
		}
		return err
	}
	if written != length {
		return errRange
	}
	return nil
}

func (r *sourceStream) Read(p []byte) (int, error) {
	if r.remaining == 0 {
		return 0, io.EOF
	}
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	index := r.offset / r.entry.store.chunkBytes
	if r.file == nil || r.fileChunk != index {
		if r.file != nil {
			_ = r.file.Close()
		}
		path, err := r.entry.ensureChunk(r.ctx, index)
		if err != nil {
			return 0, err
		}
		file, err := os.Open(path)
		if err != nil {
			return 0, errors.New("could not open playback source cache chunk")
		}
		r.file, r.fileChunk = file, index
	}
	within := r.offset % r.entry.store.chunkBytes
	count := min(int64(len(p)), r.remaining, r.entry.record.chunkLength(index, r.entry.store.chunkBytes)-within)
	n, err := r.file.ReadAt(p[:int(count)], within)
	r.offset += int64(n)
	r.remaining -= int64(n)
	r.read += int64(n)
	if r.read >= sourcePrefetchThreshold && r.prefetched != index+1 {
		r.prefetched = index + 1
		r.entry.prefetch(r.ctx, index+1)
	}
	if errors.Is(err, io.EOF) && int64(n) == count {
		err = nil
	}
	if err == nil && n == 0 {
		return 0, io.ErrNoProgress
	}
	return n, err
}

func (r *sourceStream) Close() error {
	if r.file == nil {
		return nil
	}
	return r.file.Close()
}
