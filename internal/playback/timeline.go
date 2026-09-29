package playback

import (
	"encoding/binary"
	"errors"
)

// shiftSegmentTimeline moves every sample decode time in a self-initialized
// fragmented MP4 segment forward by start seconds, so independently encoded
// segments form one continuous playlist timeline without EXT-X-DISCONTINUITY.
//
// Rationale: input -ss seeking always rebases output timestamps near zero
// (-output_ts_offset is ignored with input seeking, -copyts mangles output),
// leaving every segment with an identical ~0-based timestamp domain. Players
// map fragments by accumulated EXTINF durations; identical domains made some
// snap playback back to 0 after a few segments.
//
// It walks moov once for track timescales, then patches every tfdt
// (baseMediaDecodeTime) in every moof. On any structural anomaly it leaves
// the data untouched and reports errTimeline so the caller can degrade to
// the unshifted segment (same behavior as before) instead of failing closed.
func shiftSegmentTimeline(data []byte, start float64) error {
	if start < 0 {
		return errors.New("negative timeline start")
	}
	if start == 0 {
		return nil
	}
	moov, ok := findTopBox(data, "moov", 1<<20)
	if !ok {
		return errors.New("moov not found")
	}
	scales := trackTimescales(moov)
	if len(scales) == 0 {
		return errors.New("no track timescales")
	}
	patched := 0
	var walkErr error
	eachBox(data, func(typ string, payload []byte) bool {
		if typ != "moof" {
			return true
		}
		eachBox(payload, func(t2 string, p2 []byte) bool {
			if t2 != "traf" {
				return true
			}
			var trackID uint32
			var haveTrack bool
			eachBox(p2, func(t3 string, p3 []byte) bool {
				if t3 == "tfhd" && len(p3) >= 8 {
					trackID = binary.BigEndian.Uint32(p3[4:8])
					haveTrack = true
				}
				return true
			})
			ts, ok := scales[trackID]
			if !haveTrack || !ok || ts == 0 {
				return true
			}
			off := uint64(start*float64(ts) + 0.5)
			eachBox(p2, func(t3 string, p3 []byte) bool {
				if t3 != "tfdt" {
					return true
				}
				// Payload is version/flags(4) plus baseMediaDecodeTime:
				// u32 at [4:8] for v0, u64 at [4:12] for v1.
				if p3[0] == 1 {
					if len(p3) < 12 {
						return true
					}
					v := binary.BigEndian.Uint64(p3[4:12])
					binary.BigEndian.PutUint64(p3[4:12], v+off)
				} else {
					if len(p3) < 8 {
						return true
					}
					v := binary.BigEndian.Uint32(p3[4:8])
					if off > uint64(^uint32(0))-uint64(v) {
						walkErr = errors.New("version 0 tfdt overflows")
						return false
					}
					binary.BigEndian.PutUint32(p3[4:8], v+uint32(off))
				}
				patched++
				return true
			})
			return walkErr == nil
		})
		return walkErr == nil
	})
	if walkErr != nil {
		return walkErr
	}
	if patched == 0 {
		return errors.New("no tfdt patched")
	}
	return nil
}

// alignAACFrameTimeline places independently encoded AAC fragments on one
// global 1024-sample grid. Each segment emits a whole number of decoded AAC
// frames, so adjacent audio runs meet exactly even when video GOP boundaries
// aren't AAC frame boundaries. Run after shiftSegmentTimeline: tfdt is absolute.
func alignAACFrameTimeline(data []byte, firstSample uint64) error {
	moov, ok := findTopBox(data, "moov", 1<<20)
	if !ok {
		return errors.New("moov not found")
	}
	var audioID uint32
	eachBox(moov, func(typ string, trak []byte) bool {
		if typ != "trak" {
			return true
		}
		var id uint32
		var audio bool
		eachBox(trak, func(typ string, p []byte) bool {
			switch typ {
			case "tkhd":
				if len(p) >= 24 && p[0] == 1 {
					id = binary.BigEndian.Uint32(p[20:24])
				} else if len(p) >= 16 && p[0] == 0 {
					id = binary.BigEndian.Uint32(p[12:16])
				}
			case "mdia":
				eachBox(p, func(typ string, p []byte) bool {
					if typ == "hdlr" && len(p) >= 12 && string(p[8:12]) == "soun" {
						audio = true
					}
					return true
				})
			}
			return true
		})
		if audio {
			audioID = id
			return false
		}
		return true
	})
	if audioID == 0 || trackTimescales(moov)[audioID] != 48000 {
		return errors.New("AAC track timescale is not 48000")
	}
	var tfdt []byte
	eachBox(data, func(typ string, moof []byte) bool {
		if typ != "moof" {
			return true
		}
		eachBox(moof, func(typ string, traf []byte) bool {
			if typ != "traf" {
				return true
			}
			var id uint32
			eachBox(traf, func(typ string, p []byte) bool {
				if typ == "tfhd" && len(p) >= 8 {
					id = binary.BigEndian.Uint32(p[4:8])
				}
				return true
			})
			if id == audioID {
				eachBox(traf, func(typ string, p []byte) bool {
					if typ == "tfdt" {
						tfdt = p
					}
					return true
				})
			}
			return true
		})
		return true
	})
	if len(tfdt) < 8 {
		return errors.New("AAC decode time not found")
	}
	if tfdt[0] == 1 {
		if len(tfdt) < 12 {
			return errors.New("short AAC decode time")
		}
		binary.BigEndian.PutUint64(tfdt[4:12], firstSample)
	} else {
		if firstSample > uint64(^uint32(0)) {
			return errors.New("AAC decode time overflows")
		}
		binary.BigEndian.PutUint32(tfdt[4:8], uint32(firstSample))
	}
	return nil
}

// eachBox iterates top-level boxes in buf: typ is the fourcc, payload excludes
// the 8-byte (or 16-byte largesize) header. Malformed tails stop iteration.
func eachBox(buf []byte, fn func(typ string, payload []byte) bool) {
	off := 0
	for off+8 <= len(buf) {
		size := int(binary.BigEndian.Uint32(buf[off : off+4]))
		typ := string(buf[off+4 : off+8])
		head := 8
		if size == 1 {
			if off+16 > len(buf) {
				return
			}
			size = int(binary.BigEndian.Uint64(buf[off+8 : off+16]))
			head = 16
		}
		if size < head || off+size > len(buf) {
			return
		}
		if size == 0 {
			if !fn(typ, buf[off+head:]) {
				return
			}
			return
		}
		if !fn(typ, buf[off+head:off+size]) {
			return
		}
		off += size
	}
}

// findTopBox returns the payload of the first top-level box with the given
// type within the first scanLimit bytes.
func findTopBox(buf []byte, want string, scanLimit int) ([]byte, bool) {
	end := min(len(buf), scanLimit)
	var found []byte
	var ok bool
	eachBox(buf[:end], func(typ string, payload []byte) bool {
		if typ == want {
			found, ok = payload, true
			return false
		}
		return true
	})
	return found, ok
}

// trackTimescales maps track_ID to media timescale from moov payload.
func trackTimescales(moov []byte) map[uint32]uint32 {
	out := map[uint32]uint32{}
	eachBox(moov, func(typ string, payload []byte) bool {
		if typ != "trak" {
			return true
		}
		var id uint32
		var haveID bool
		var scale uint32
		eachBox(payload, func(t2 string, p2 []byte) bool {
			switch t2 {
			case "tkhd":
				// v0: version/flags(4) ctime(4) mtime(4) track_ID(4);
				// v1: 8-byte creation/modification times instead.
				if p2[0] == 1 {
					if len(p2) >= 24 {
						id = binary.BigEndian.Uint32(p2[20:24])
						haveID = id != 0
					}
				} else if len(p2) >= 16 {
					id = binary.BigEndian.Uint32(p2[12:16])
					haveID = id != 0
				}
			case "mdia":
				eachBox(p2, func(t3 string, p3 []byte) bool {
					if t3 != "mdhd" || len(p3) < 24 {
						return true
					}
					if p3[0] == 1 {
						if len(p3) < 32 {
							return true
						}
						scale = binary.BigEndian.Uint32(p3[24:28])
					} else {
						scale = binary.BigEndian.Uint32(p3[12:16])
					}
					return true
				})
			}
			return true
		})
		if haveID && scale != 0 {
			out[id] = scale
		}
		return true
	})
	return out
}

// walkTopBoxes calls fn for every top-level box in data with its type and byte
// range. Iteration stops early when fn returns false or a box is malformed.
// A zero size means the box extends to the end of data, matching ISO-BMFF.
func walkTopBoxes(data []byte, fn func(typ string, start, end, payload int) bool) {
	off := 0
	for off+8 <= len(data) {
		size := int(binary.BigEndian.Uint32(data[off : off+4]))
		typ := string(data[off+4 : off+8])
		head := 8
		if size == 1 {
			if off+16 > len(data) {
				return
			}
			size = int(binary.BigEndian.Uint64(data[off+8 : off+16]))
			head = 16
		}
		end := len(data)
		if size != 0 {
			if size < head || off+size > len(data) {
				return
			}
			end = off + size
		}
		if !fn(typ, off, end, off+head) {
			return
		}
		off = end
	}
}

// splitInit divides a self-initialized fragmented MP4 segment into its
// initialization run (ftyp+moov) and its media run (moof+mdat...). HLS serves
// the init once as EXT-X-MAP and every media segment without it, because a
// moov embedded in each fragment makes players reset their decoder on the
// repeated moov.
func splitInit(data []byte) (init, media []byte, ok bool) {
	end := -1
	sawMoof := false
	walkTopBoxes(data, func(typ string, start, stop, payload int) bool {
		switch typ {
		case "ftyp":
			if start != 0 {
				return false
			}
		case "moov":
			if end != -1 {
				return false
			}
			end = stop
		case "moof":
			if end == -1 {
				return false
			}
			sawMoof = true
			return false
		}
		return true
	})
	if !sawMoof {
		return nil, nil, false
	}
	return data[:end], data[end:], true
}

// SplitInit exposes splitInit to the HTTP layer.
func SplitInit(data []byte) (init, media []byte, ok bool) {
	return splitInit(data)
}

// renumberFragments rewrites every top-level moof's mfhd sequence number so
// independently encoded segments form one contiguous global sequence in
// playlist order. VLC 4 treats a sequence gap as a passive seek and resets
// inter-frame prediction, so a per-segment reset to 1 breaks decoding. It
// returns the number of fragments patched.
func renumberFragments(data []byte, first uint32) (int, error) {
	seq := first
	count := 0
	var err error
	walkTopBoxes(data, func(typ string, start, stop, payload int) bool {
		if typ != "moof" {
			return true
		}
		if err = setFragmentSequence(data[payload:stop], seq); err != nil {
			return false
		}
		seq++
		count++
		return true
	})
	if err != nil {
		return count, err
	}
	if count == 0 {
		return 0, errors.New("playback segment has no fragment header")
	}
	return count, nil
}

// setFragmentSequence writes seq into the first mfhd child of a moof payload.
// mfhd is muxer-mandated to be the first child of moof: size(4) type(4)
// version+flags(4) sequence_number(4).
func setFragmentSequence(moof []byte, seq uint32) error {
	if len(moof) < 16 || string(moof[4:8]) != "mfhd" {
		return errors.New("playback fragment has no sequence header")
	}
	binary.BigEndian.PutUint32(moof[12:16], seq)
	return nil
}
