package playback

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"reflect"
	"testing"
)

func testID(id uint64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], id)
	n := 0
	for n < 7 && b[n] == 0 {
		n++
	}
	return append([]byte(nil), b[n:]...)
}

func testSize(size uint64) []byte {
	for width := 1; width <= 8; width++ {
		if size < uint64(1)<<(7*width)-1 {
			var b [8]byte
			binary.BigEndian.PutUint64(b[:], size)
			b[8-width] |= byte(1 << (8 - width))
			return append([]byte(nil), b[8-width:]...)
		}
	}
	panic("test size exceeds EBML limit")
}

func testElement(id uint64, fields ...[]byte) []byte {
	payload := bytes.Join(fields, nil)
	b := append(testID(id), testSize(uint64(len(payload)))...)
	return append(b, payload...)
}

func testUint(id, v uint64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], v)
	return testElement(id, b[:])
}

func testFloat(id uint64, v float64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], math.Float64bits(v))
	return testElement(id, b[:])
}

func testTrack(number, kind uint64, codec string) []byte {
	return testElement(0xAE, testUint(0xD7, number), testUint(0x83, kind), testElement(0x86, []byte(codec)))
}

func testCue(ticks uint64, tracks ...uint64) []byte {
	fields := [][]byte{testUint(0xB3, ticks)}
	for _, track := range tracks {
		fields = append(fields, testElement(0xB7, testUint(0xF7, track), testUint(0xF1, 0)))
	}
	return testElement(0xBB, fields...)
}

func testDocument(info, tracks, cues []byte) []byte {
	return bytes.Join([][]byte{
		testElement(idEBML, testElement(0x4282, []byte("matroska"))),
		testElement(idSegment, info, tracks, cues),
	}, nil)
}

func testMetadata() (info, tracks, cues []byte) {
	info = testElement(idInfo, testUint(0x2AD7B1, 2000000), testFloat(0x4489, 10050.5))
	// Audio comes first; the selected video has TrackNumber 7, not 1.
	tracks = testElement(idTracks,
		testTrack(3, 2, "A_TRUEHD"),
		testTrack(7, 1, "V_MPEGH/ISO/HEVC"),
		testTrack(9, 1, "V_MPEG4/ISO/AVC"),
		testTrack(10, 2, "A_AAC"))
	cues = testElement(idCues,
		testCue(9500, 7), testCue(0, 7), testCue(3000, 3, 7),
		testCue(3000, 7), testCue(1500, 7), testCue(6500, 7),
		testCue(6000, 3), testCue(6000, 9))
	return
}

func TestReadIndexTrackSelectionAndTimeline(t *testing.T) {
	info, tracks, cues := testMetadata()
	data := testDocument(info, tracks, cues)
	index, err := ReadIndex(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	want := Index{Duration: 20.101, Boundaries: []float64{0, 6, 13, 19, 20.101},
		seekTimes: []float64{0, 9.5, 16, 19.5505}, VideoCodec: "hevc", AudioCodec: "truehd"}
	if !reflect.DeepEqual(index, want) {
		t.Fatalf("got %#v, want %#v", index, want)
	}
}

type indexFragment struct {
	offset int64
	data   []byte
}

type sparseIndexReader struct {
	fragments []indexFragment
	readBytes int
	mediaRead bool
}

func (r *sparseIndexReader) ReadAt(p []byte, off int64) (int, error) {
	for _, fragment := range r.fragments {
		if off >= fragment.offset && off-fragment.offset <= int64(len(fragment.data)) &&
			int64(len(p)) <= int64(len(fragment.data))-(off-fragment.offset) {
			copy(p, fragment.data[off-fragment.offset:])
			r.readBytes += len(p)
			return len(p), nil
		}
	}
	r.mediaRead = true
	return 0, io.ErrUnexpectedEOF
}

func TestReadIndexSeekHeadRelativeOffsets(t *testing.T) {
	info, tracks, cues := testMetadata()
	seek := func(id uint64, position uint64) []byte {
		return testElement(0x4DBB, testElement(0x53AB, testID(id)), testUint(0x53AC, position))
	}
	seekHead := testElement(idSeekHead, seek(idInfo, 0), seek(idTracks, 0), seek(idCues, 0))
	const clusterBytes = uint64(1 << 34)
	clusterHeader := append(testID(0x1F43B675), testSize(clusterBytes)...)
	infoOffset := uint64(len(seekHead)+len(clusterHeader)) + clusterBytes
	seekHead = testElement(idSeekHead, seek(idInfo, infoOffset),
		seek(idTracks, infoOffset+uint64(len(info))),
		seek(idCues, infoOffset+uint64(len(info)+len(tracks))))
	prefix := testElement(idEBML, testElement(0x4282, []byte("matroska")))
	prefix = append(prefix, testElement(0xEC, make([]byte, 37))...)
	prefix = append(prefix, testID(idSegment)...)
	prefix = append(prefix, 0xFF) // Unknown-size Segment, bounded by source size.
	segmentOffset := int64(len(prefix))
	prefix = append(prefix, seekHead...)
	prefix = append(prefix, clusterHeader...)
	suffix := bytes.Join([][]byte{info, tracks, cues}, nil)
	r := &sparseIndexReader{fragments: []indexFragment{
		{0, prefix}, {segmentOffset + int64(infoOffset), suffix},
	}}
	index, err := ReadIndex(r, segmentOffset+int64(infoOffset)+int64(len(suffix)))
	if err != nil {
		t.Fatal(err)
	}
	if index.Duration != 20.101 || !reflect.DeepEqual(index.Boundaries, []float64{0, 6, 13, 19, 20.101}) {
		t.Fatalf("wrong seekhead-relative index: %#v", index)
	}
	if r.mediaRead || r.readBytes > len(prefix)+len(suffix) {
		t.Fatalf("read media or exceeded metadata-only reads: media=%v bytes=%d", r.mediaRead, r.readBytes)
	}
}

func TestReadIndexSkipsClusterWithoutSeekHead(t *testing.T) {
	info, tracks, cues := testMetadata()
	const clusterBytes = uint64(1 << 34)
	clusterHeader := append(testID(0x1F43B675), testSize(clusterBytes)...)
	prefix := testElement(idEBML, testElement(0x4282, []byte("matroska")))
	prefix = append(prefix, testID(idSegment)...)
	prefix = append(prefix, 0xFF)
	prefix = append(prefix, clusterHeader...)
	suffix := bytes.Join([][]byte{info, tracks, cues}, nil)
	r := &sparseIndexReader{fragments: []indexFragment{{0, prefix}, {int64(len(prefix)) + int64(clusterBytes), suffix}}}
	index, err := ReadIndex(r, int64(len(prefix)+len(suffix))+int64(clusterBytes))
	if err != nil {
		t.Fatal(err)
	}
	if index.VideoCodec != "hevc" || r.mediaRead {
		t.Fatalf("failed metadata-only cluster skip: %#v media=%v", index, r.mediaRead)
	}
}

func TestReadIndexRejectsTruncation(t *testing.T) {
	info, tracks, cues := testMetadata()
	data := testDocument(info, tracks, cues)
	for size := range len(data) {
		if _, err := ReadIndex(bytes.NewReader(data[:size]), int64(size)); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("truncation at %d: got %v", size, err)
		}
	}
	if _, err := ReadIndex(bytes.NewReader(data[:len(data)-1]), int64(len(data))); !errors.Is(err, ErrUnsupported) {
		t.Fatalf("short ReaderAt with claimed complete size: %v", err)
	}
}

func TestReadIndexRejectsInvalidStructureAndTiming(t *testing.T) {
	info, tracks, cues := testMetadata()
	valid := testDocument(info, tracks, cues)
	seekOverflow := testElement(idSeekHead,
		testElement(0x4DBB, testElement(0x53AB, testID(idInfo)), testUint(0x53AC, math.MaxUint64)))
	wrongSeek := testElement(idSeekHead,
		testElement(0x4DBB, testElement(0x53AB, testID(idInfo)), testUint(0x53AC, 0)))
	header := testElement(idEBML, testElement(0x4282, []byte("matroska")))
	oversize := append(testID(idInfo), testSize(maxIndexBytes+1)...)
	cases := map[string][]byte{
		"other container":          []byte("not an EBML document"),
		"zero vint":                append(append([]byte(nil), header...), 0),
		"unknown metadata size":    testDocument([]byte{0x15, 0x49, 0xA9, 0x66, 0xFF}, tracks, cues),
		"seek overflow":            testDocument(seekOverflow, tracks, cues),
		"seek wrong target":        testDocument(wrongSeek, tracks, cues),
		"missing cues":             testDocument(info, tracks, nil),
		"audio cues only":          testDocument(info, tracks, testElement(idCues, testCue(0, 3))),
		"cues beyond duration":     testDocument(info, tracks, testElement(idCues, testCue(10051, 7))),
		"nonfinite duration":       testDocument(testElement(idInfo, testFloat(0x4489, math.Inf(1))), tracks, cues),
		"nan duration":             testDocument(testElement(idInfo, testFloat(0x4489, math.NaN())), tracks, cues),
		"zero duration":            testDocument(testElement(idInfo, testFloat(0x4489, 0)), tracks, cues),
		"zero timestamp scale":     testDocument(testElement(idInfo, testFloat(0x4489, 100), testUint(0x2AD7B1, 0)), tracks, cues),
		"oversize nested metadata": testDocument(oversize, tracks, cues),
		"duplicate track numbers":  testDocument(info, testElement(idTracks, testTrack(7, 1, "V_MPEGH/ISO/HEVC"), testTrack(7, 2, "A_TRUEHD")), cues),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := ReadIndex(bytes.NewReader(data), int64(len(data))); !errors.Is(err, ErrUnsupported) {
				t.Fatalf("got %v, want unsupported", err)
			}
		})
	}
	// A declared metadata payload over the allocation budget must be rejected
	// without attempting any read from its virtual body.
	prefix := append(append([]byte(nil), header...), testID(idSegment)...)
	prefix = append(prefix, 0xFF)
	prefix = append(prefix, oversize...)
	r := &sparseIndexReader{fragments: []indexFragment{{0, prefix}}}
	if _, err := ReadIndex(r, int64(len(prefix))+maxIndexBytes+1); !errors.Is(err, ErrUnsupported) || r.mediaRead {
		t.Fatalf("oversize allocation guard: err=%v payloadRead=%v", err, r.mediaRead)
	}
	if _, err := ReadIndex(bytes.NewReader(valid), math.MaxInt64); err != nil {
		// The finite Segment bounds the source even if its enclosing size is huge.
		t.Fatalf("finite segment with large enclosing bound: %v", err)
	}
}

func TestReadIndexMissingAudioAndDefaultScale(t *testing.T) {
	data := testDocument(testElement(idInfo, testFloat(0x4489, 12500)),
		testElement(idTracks, testTrack(2, 1, "V_MPEG4/ISO/AVC")),
		testElement(idCues, testCue(0, 2), testCue(6000, 2), testCue(12000, 2)))
	index, err := ReadIndex(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if index.AudioCodec != "" || index.VideoCodec != "h264" || !reflect.DeepEqual(index.Boundaries, []float64{0, 6, 12, 12.5}) {
		t.Fatalf("wrong default scale or missing-audio behavior: %#v", index)
	}
}
