package playback

import (
	"encoding/binary"
	"errors"
	"io"
	"math"
	"sort"
	"strings"
)

// ErrUnsupported means the source has no usable, bounded Matroska VOD index.
var ErrUnsupported = errors.New("playback: unsupported or malformed Matroska index")

// Index describes the first video and audio tracks, matching ffmpeg's 0:v:0
// and 0:a:0 selection. Boundaries are keyframe times in seconds, followed by
// the exact presentation duration.
type Index struct {
	Duration   float64
	Boundaries []float64
	VideoCodec string
	AudioCodec string
	// Seek inside the boundary's first GOP, not exactly on its cue. FFmpeg's
	// DTS seek heuristic can otherwise select the preceding GOP for B-frames.
	seekTimes []float64
}

const (
	idEBML     = 0x1A45DFA3
	idSegment  = 0x18538067
	idSeekHead = 0x114D9B74
	idInfo     = 0x1549A966
	idTracks   = 0x1654AE6B
	idCues     = 0x1C53BB6B

	maxIndexBytes = 16 << 20
	maxIndexReads = 32768
	maxTopEntries = 4096
	maxSeekHeads  = 64
)

type indexElement struct {
	id      uint64
	data    int64
	end     int64
	unknown bool
}

type indexReader struct {
	r     io.ReaderAt
	size  int64
	bytes int64
	reads int
}

func (r *indexReader) read(p []byte, off int64) error {
	if off < 0 || off > r.size || int64(len(p)) > r.size-off ||
		r.reads >= maxIndexReads || int64(len(p)) > maxIndexBytes-r.bytes {
		return ErrUnsupported
	}
	r.reads++
	r.bytes += int64(len(p))
	n, err := r.r.ReadAt(p, off)
	if n != len(p) || (err != nil && err != io.EOF) {
		// Do not expose transport errors, which can contain signed source URLs.
		return ErrUnsupported
	}
	return nil
}

// vint reads only the header bytes, never peeking into a Cluster payload.
func (r *indexReader) vint(off, end int64, id bool) (uint64, int64, bool, error) {
	var b [8]byte
	if off >= end || r.read(b[:1], off) != nil {
		return 0, 0, false, ErrUnsupported
	}
	n, marker := vintWidth(b[0])
	if n == 0 || (id && n > 4) || int64(n) > end-off {
		return 0, 0, false, ErrUnsupported
	}
	if n > 1 && r.read(b[1:n], off+1) != nil {
		return 0, 0, false, ErrUnsupported
	}
	v := uint64(b[0])
	if !id {
		v &= uint64(marker - 1)
	}
	for _, x := range b[1:n] {
		v = v<<8 | uint64(x)
	}
	unknown := !id && v == uint64(1)<<(7*n)-1
	return v, int64(n), unknown, nil
}

func vintWidth(b byte) (int, byte) {
	for n, mask := 1, byte(0x80); n <= 8; n, mask = n+1, mask>>1 {
		if b&mask != 0 {
			return n, mask
		}
	}
	return 0, 0
}

func (r *indexReader) element(off, end int64) (indexElement, error) {
	id, n, _, err := r.vint(off, end, true)
	if err != nil {
		return indexElement{}, err
	}
	size, m, unknown, err := r.vint(off+n, end, false)
	if err != nil {
		return indexElement{}, err
	}
	data := off + n + m
	if !unknown && size > uint64(end-data) {
		return indexElement{}, ErrUnsupported
	}
	e := indexElement{id: id, data: data, end: end, unknown: unknown}
	if !unknown {
		e.end = data + int64(size)
	}
	return e, nil
}

func (r *indexReader) payload(e indexElement) ([]byte, error) {
	if e.unknown || e.end-e.data > maxIndexBytes-r.bytes {
		return nil, ErrUnsupported
	}
	b := make([]byte, int(e.end-e.data))
	if err := r.read(b, e.data); err != nil {
		return nil, err
	}
	return b, nil
}

// indexFields walks a known-size metadata master. There is no recursive walk
// of arbitrary input: callers descend only through the known Matroska schema.
func indexFields(b []byte, visit func(uint64, []byte) error) error {
	for len(b) > 0 {
		n, _ := vintWidth(b[0])
		if n == 0 || n > 4 || n >= len(b) {
			return ErrUnsupported
		}
		var id uint64
		for _, x := range b[:n] {
			id = id<<8 | uint64(x)
		}
		b = b[n:]
		m, marker := vintWidth(b[0])
		if m == 0 || m > len(b) {
			return ErrUnsupported
		}
		size := uint64(b[0] & (marker - 1))
		for _, x := range b[1:m] {
			size = size<<8 | uint64(x)
		}
		b = b[m:]
		if size == uint64(1)<<(7*m)-1 || size > uint64(len(b)) {
			return ErrUnsupported
		}
		if err := visit(id, b[:int(size)]); err != nil {
			return err
		}
		b = b[int(size):]
	}
	return nil
}

func indexUint(b []byte) (uint64, error) {
	if len(b) == 0 || len(b) > 8 {
		return 0, ErrUnsupported
	}
	var v uint64
	for _, x := range b {
		v = v<<8 | uint64(x)
	}
	return v, nil
}

func indexFloat(b []byte) (float64, error) {
	var v float64
	switch len(b) {
	case 4:
		v = float64(math.Float32frombits(binary.BigEndian.Uint32(b)))
	case 8:
		v = math.Float64frombits(binary.BigEndian.Uint64(b))
	default:
		return 0, ErrUnsupported
	}
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, ErrUnsupported
	}
	return v, nil
}

// ReadIndex uses SeekHead offsets or a bounded top-level scan. Cluster payloads
// are skipped by their declared sizes; media is never scanned or downloaded.
// Unknown-size Segments are supported, but an unknown-size Cluster cannot be
// skipped safely when metadata has not yet been located.
func ReadIndex(source io.ReaderAt, size int64) (Index, error) {
	if source == nil || size <= 0 {
		return Index{}, ErrUnsupported
	}
	r := &indexReader{r: source, size: size}
	header, err := r.element(0, size)
	if err != nil || header.id != idEBML {
		return Index{}, ErrUnsupported
	}
	b, err := r.payload(header)
	if err != nil {
		return Index{}, err
	}
	docType := ""
	if err = indexFields(b, func(id uint64, value []byte) error {
		if id == 0x4282 {
			docType = string(value)
		}
		return nil
	}); err != nil || docType != "matroska" {
		return Index{}, ErrUnsupported
	}
	var segment indexElement
	off := header.end
	for count := 0; count < maxTopEntries && off < size; count++ {
		segment, err = r.element(off, size)
		if err != nil {
			return Index{}, err
		}
		if segment.id == idSegment {
			break
		}
		if segment.unknown || (segment.id != 0xEC && segment.id != 0xBF) {
			return Index{}, ErrUnsupported
		}
		off = segment.end
	}
	if segment.id != idSegment {
		return Index{}, ErrUnsupported
	}

	metadata := make(map[uint64][]byte, 3)
	seenHeads := make(map[int64]bool)
	type seekTarget struct {
		id  uint64
		off int64
	}
	var pending []seekTarget
	load := func(e indexElement) error {
		if e.id != idSeekHead && e.id != idInfo && e.id != idTracks && e.id != idCues {
			return nil
		}
		if e.id == idSeekHead {
			if seenHeads[e.data] {
				return nil
			}
			if len(seenHeads) >= maxSeekHeads {
				return ErrUnsupported
			}
			seenHeads[e.data] = true
		} else if _, ok := metadata[e.id]; ok {
			return nil
		}
		payload, readErr := r.payload(e)
		if readErr != nil {
			return readErr
		}
		if e.id != idSeekHead {
			metadata[e.id] = payload
			return nil
		}
		return indexFields(payload, func(id uint64, entry []byte) error {
			if id != 0x4DBB {
				return nil
			}
			var targetID, position uint64
			hasID, hasPosition := false, false
			if parseErr := indexFields(entry, func(field uint64, value []byte) error {
				var valueErr error
				switch field {
				case 0x53AB:
					if len(value) == 0 || len(value) > 4 {
						return ErrUnsupported
					}
					targetID, valueErr = indexUint(value)
					hasID = true
				case 0x53AC:
					position, valueErr = indexUint(value)
					hasPosition = true
				}
				return valueErr
			}); parseErr != nil || !hasID || !hasPosition || position >= uint64(segment.end-segment.data) {
				return ErrUnsupported
			}
			if targetID == idSeekHead || targetID == idInfo || targetID == idTracks || targetID == idCues {
				if len(pending) >= maxTopEntries {
					return ErrUnsupported
				}
				pending = append(pending, seekTarget{targetID, segment.data + int64(position)})
			}
			return nil
		})
	}

	off = segment.data
	for count := 0; count < maxTopEntries && len(metadata) < 3; count++ {
		var e indexElement
		if len(pending) > 0 {
			target := pending[len(pending)-1]
			pending = pending[:len(pending)-1]
			e, err = r.element(target.off, segment.end)
			if err != nil || e.id != target.id {
				return Index{}, ErrUnsupported
			}
		} else {
			if off >= segment.end {
				break
			}
			e, err = r.element(off, segment.end)
			if err != nil || e.unknown {
				return Index{}, ErrUnsupported
			}
			off = e.end
		}
		if err = load(e); err != nil {
			return Index{}, err
		}
	}
	if len(metadata) != 3 {
		return Index{}, ErrUnsupported
	}
	return buildIndex(metadata[idInfo], metadata[idTracks], metadata[idCues], segment.end-segment.data)
}

func buildIndex(info, tracks, cues []byte, segmentSize int64) (Index, error) {
	var result Index
	scale := uint64(1000000)
	duration := float64(0)
	if err := indexFields(info, func(id uint64, value []byte) error {
		var err error
		switch id {
		case 0x2AD7B1:
			scale, err = indexUint(value)
		case 0x4489:
			duration, err = indexFloat(value)
		}
		return err
	}); err != nil || scale == 0 || duration <= 0 {
		return Index{}, ErrUnsupported
	}
	secondsPerTick := float64(scale) / 1e9
	result.Duration = duration * secondsPerTick
	if math.IsInf(result.Duration, 0) || result.Duration <= 0 {
		return Index{}, ErrUnsupported
	}

	var videoTrack uint64
	seenTracks := make(map[uint64]bool)
	haveAudio := false
	if err := indexFields(tracks, func(id uint64, entry []byte) error {
		if id != 0xAE {
			return nil
		}
		var number, kind uint64
		codec := ""
		trackScale := float64(1)
		var offset, delay uint64
		if err := indexFields(entry, func(field uint64, value []byte) error {
			var err error
			switch field {
			case 0xD7:
				number, err = indexUint(value)
			case 0x83:
				kind, err = indexUint(value)
			case 0x86:
				if len(value) > 256 {
					return ErrUnsupported
				}
				codec = string(value)
			case 0x23314F:
				trackScale, err = indexFloat(value)
			case 0x537F:
				offset, err = indexUint(value)
			case 0x56AA:
				delay, err = indexUint(value)
			}
			return err
		}); err != nil || number == 0 || kind == 0 || codec == "" || seenTracks[number] {
			return ErrUnsupported
		}
		seenTracks[number] = true
		if kind == 1 && videoTrack == 0 {
			// Nondefault legacy track timing needs a different seek timeline.
			if trackScale != 1 || offset != 0 || delay != 0 {
				return ErrUnsupported
			}
			videoTrack = number
			result.VideoCodec = normalizeCodec(codec)
		}
		if kind == 2 && !haveAudio {
			haveAudio = true
			result.AudioCodec = normalizeCodec(codec)
		}
		return nil
	}); err != nil || videoTrack == 0 {
		return Index{}, ErrUnsupported
	}

	var times []float64
	if err := indexFields(cues, func(id uint64, point []byte) error {
		if id != 0xBB {
			return nil
		}
		var ticks uint64
		hasTime, selected := false, false
		if err := indexFields(point, func(field uint64, value []byte) error {
			switch field {
			case 0xB3:
				var err error
				ticks, err = indexUint(value)
				hasTime = true
				return err
			case 0xB7:
				var track, cluster uint64
				hasCluster, reference := false, false
				if err := indexFields(value, func(position uint64, data []byte) error {
					var err error
					switch position {
					case 0xF7:
						track, err = indexUint(data)
					case 0xF1:
						cluster, err = indexUint(data)
						hasCluster = true
					case 0xDB:
						reference = true
					}
					return err
				}); err != nil || track == 0 || !hasCluster || cluster >= uint64(segmentSize) {
					return ErrUnsupported
				}
				if track == videoTrack && !reference {
					selected = true
				}
			}
			return nil
		}); err != nil || !hasTime || ticks > 1<<53 {
			return ErrUnsupported
		}
		if selected {
			seconds := float64(ticks) * secondsPerTick
			if math.IsInf(seconds, 0) || seconds > result.Duration {
				return ErrUnsupported
			}
			if seconds < result.Duration {
				times = append(times, seconds)
			}
		}
		return nil
	}); err != nil || len(times) == 0 {
		return Index{}, ErrUnsupported
	}
	sort.Float64s(times)
	result.Boundaries = []float64{0}
	for _, seconds := range times {
		if seconds-result.Boundaries[len(result.Boundaries)-1] >= 6 {
			result.Boundaries = append(result.Boundaries, seconds)
		}
	}
	result.Boundaries = append(result.Boundaries, result.Duration)
	result.seekTimes = make([]float64, len(result.Boundaries)-1)
	cue := 0
	for n, start := range result.Boundaries[:len(result.Boundaries)-1] {
		for cue < len(times) && times[cue] <= start {
			cue++
		}
		if n == 0 {
			continue
		}
		next := result.Duration
		if cue < len(times) {
			next = times[cue]
		}
		result.seekTimes[n] = start + (next-start)/2
	}
	return result, nil
}

func normalizeCodec(codec string) string {
	switch codec {
	case "V_MPEGH/ISO/HEVC":
		return "hevc"
	case "V_MPEG4/ISO/AVC":
		return "h264"
	case "A_TRUEHD":
		return "truehd"
	case "A_DTS", "A_DTS/LOSSLESS", "A_DTS/EXPRESS":
		return "dts"
	case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10":
		return "ac3"
	case "A_EAC3":
		return "eac3"
	case "A_AAC":
		return "aac"
	}
	if strings.HasPrefix(codec, "A_AAC/") {
		return "aac"
	}
	return strings.ToLower(codec)
}
