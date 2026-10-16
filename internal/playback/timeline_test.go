package playback

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"testing"
)

func mkbox(typ string, payload []byte) []byte {
	b := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(b[0:4], uint32(len(b)))
	copy(b[4:8], typ)
	copy(b[8:], payload)
	return b
}

func tkhdV0(id uint32) []byte {
	p := make([]byte, 24)
	p[0] = 0
	binary.BigEndian.PutUint32(p[12:16], id)
	return mkbox("tkhd", p)
}

func tkhdV1(id uint32) []byte {
	p := make([]byte, 32)
	p[0] = 1
	binary.BigEndian.PutUint32(p[20:24], id)
	return mkbox("tkhd", p)
}

func mdhdV0(timescale uint32) []byte {
	p := make([]byte, 24)
	p[0] = 0
	binary.BigEndian.PutUint32(p[12:16], timescale)
	return mkbox("mdhd", p)
}

func mdhdV1(timescale uint32) []byte {
	p := make([]byte, 36)
	p[0] = 1
	binary.BigEndian.PutUint32(p[24:28], timescale)
	return mkbox("mdhd", p)
}

func tfhd(id uint32) []byte {
	p := make([]byte, 8)
	binary.BigEndian.PutUint32(p[4:8], id)
	return mkbox("tfhd", p)
}

func tfdtV0(t uint32) []byte {
	p := make([]byte, 8)
	p[0] = 0
	binary.BigEndian.PutUint32(p[4:8], t)
	return mkbox("tfdt", p)
}

func tfdtV1(t uint64) []byte {
	p := make([]byte, 12)
	p[0] = 1
	binary.BigEndian.PutUint64(p[4:12], t)
	return mkbox("tfdt", p)
}

func TestShiftSegmentTimeline(t *testing.T) {
	moov := mkbox("moov", bytes.Join([][]byte{
		mkbox("trak", bytes.Join([][]byte{
			tkhdV0(1), mkbox("mdia", mdhdV0(90000)),
		}, nil)),
		mkbox("trak", bytes.Join([][]byte{
			tkhdV1(2), mkbox("mdia", mdhdV1(48000)),
		}, nil)),
	}, nil))
	moof := func() []byte {
		return mkbox("moof", bytes.Join([][]byte{
			mkbox("traf", bytes.Join([][]byte{tfhd(1), tfdtV0(3780)}, nil)),
			mkbox("traf", bytes.Join([][]byte{tfhd(2), tfdtV1(1024)}, nil)),
			mkbox("traf", bytes.Join([][]byte{tfhd(9), tfdtV0(100)}, nil)),
		}, nil))
	}
	data := bytes.Join([][]byte{mkbox("ftyp", []byte("isom")), moov, moof()}, nil)
	if err := shiftSegmentTimeline(data, 10.0); err != nil {
		t.Fatalf("shift failed: %v", err)
	}
	// Re-parse: collect tfdt values per track.
	got := map[uint32]uint64{}
	eachBox(data, func(typ string, p []byte) bool {
		if typ != "moof" {
			return true
		}
		eachBox(p, func(t2 string, p2 []byte) bool {
			if t2 != "traf" {
				return true
			}
			var id uint32
			eachBox(p2, func(t3 string, p3 []byte) bool {
				if t3 == "tfhd" {
					id = binary.BigEndian.Uint32(p3[4:8])
				}
				if t3 == "tfdt" {
					if p3[0] == 1 {
						got[id] = binary.BigEndian.Uint64(p3[4:12])
					} else {
						got[id] = uint64(binary.BigEndian.Uint32(p3[4:8]))
					}
				}
				return true
			})
			return true
		})
		return true
	})
	if got[1] != 3780+900000 {
		t.Fatalf("video tfdt = %d, want %d", got[1], 3780+900000)
	}
	if got[2] != 1024+480000 {
		t.Fatalf("audio tfdt = %d, want %d", got[2], 1024+480000)
	}
	if got[9] != 100 {
		t.Fatalf("unknown track must be untouched, got %d", got[9])
	}
}

func TestAlignAACFrameTimeline(t *testing.T) {
	handler := make([]byte, 12)
	copy(handler[8:12], "soun")
	moov := mkbox("moov", bytes.Join([][]byte{
		mkbox("trak", bytes.Join([][]byte{tkhdV0(1), mkbox("mdia", mdhdV0(90000))}, nil)),
		mkbox("trak", bytes.Join([][]byte{tkhdV1(2), mkbox("mdia", bytes.Join([][]byte{mdhdV1(48000), mkbox("hdlr", handler)}, nil))}, nil)),
	}, nil))
	for _, version := range []int{0, 1} {
		t.Run(string(rune('0'+version)), func(t *testing.T) {
			var audio []byte
			if version == 0 {
				audio = tfdtV0(480000)
			} else {
				audio = tfdtV1(480000)
			}
			data := bytes.Join([][]byte{moov, mkbox("moof", bytes.Join([][]byte{
				mkbox("traf", bytes.Join([][]byte{tfhd(1), tfdtV1(900000)}, nil)),
				mkbox("traf", bytes.Join([][]byte{tfhd(2), audio}, nil)),
			}, nil))}, nil)
			if err := alignAACFrameTimeline(data, 469*1024); err != nil {
				t.Fatal(err)
			}
			if got := binary.BigEndian.Uint32(data[len(data)-4:]); got != 469*1024 {
				t.Fatalf("v%d decode time = %d", version, got)
			}
			if !bytes.Contains(data, tfdtV1(900000)) {
				t.Fatal("video decode time changed")
			}
		})
	}
	if err := alignAACFrameTimeline(mkbox("ftyp", []byte("isom")), 0); err == nil {
		t.Fatal("expected missing audio track error")
	}
}

func TestShiftSegmentTimelineRejectsV0Overflow(t *testing.T) {
	moov := mkbox("moov", mkbox("trak", bytes.Join([][]byte{
		tkhdV0(1), mkbox("mdia", mdhdV0(90000)),
	}, nil)))
	data := bytes.Join([][]byte{
		mkbox("ftyp", []byte("isom")),
		moov,
		mkbox("moof", mkbox("traf", bytes.Join([][]byte{
			tfhd(1), tfdtV0(^uint32(0) - 10),
		}, nil))),
	}, nil)
	original := append([]byte(nil), data...)
	if err := shiftSegmentTimeline(data, 1); err == nil {
		t.Fatal("expected version 0 tfdt overflow error")
	}
	if !bytes.Equal(data, original) {
		t.Fatal("overflowing tfdt was modified")
	}
}

func TestShiftSegmentTimelineDegrades(t *testing.T) {
	if err := shiftSegmentTimeline([]byte("junk"), 5); err == nil {
		t.Fatal("expected error on non-boxes")
	}
	data := bytes.Join([][]byte{mkbox("ftyp", []byte("isom"))}, nil)
	if err := shiftSegmentTimeline(data, 5); err == nil {
		t.Fatal("expected error without moov")
	}
	if err := shiftSegmentTimeline(data, 0); err != nil {
		t.Fatalf("start 0 must be no-op: %v", err)
	}
	if err := shiftSegmentTimeline(data, -1); err == nil {
		t.Fatal("expected error on negative start")
	}
}

// trun builds a version 0 trun with data offset plus per-sample duration,
// size and composition offset fields, the layout ffmpeg writes for video.
func trun(durations, offsets []uint32) []byte {
	p := make([]byte, 12+len(durations)*12)
	binary.BigEndian.PutUint32(p[0:4], 0x1|0x100|0x200|0x800)
	binary.BigEndian.PutUint32(p[4:8], uint32(len(durations)))
	for i, d := range durations {
		at := 12 + i*12
		binary.BigEndian.PutUint32(p[at:at+4], d)
		binary.BigEndian.PutUint32(p[at+4:at+8], 1000+uint32(i)) // size
		binary.BigEndian.PutUint32(p[at+8:at+12], offsets[i])
	}
	return mkbox("trun", p)
}

// videoTiming decodes a single-trun segment built by trun into the summed
// durations and each sample's presentation time relative to the keyframe.
func videoTiming(data []byte) (sum int64, presentations []int64) {
	run := data[bytes.LastIndex(data, []byte("trun"))+4:]
	count := int(binary.BigEndian.Uint32(run[4:8]))
	var dts int64
	origin := int64(binary.BigEndian.Uint32(run[12+8 : 12+12]))
	for i := 0; i < count; i++ {
		at := 12 + i*12
		presentations = append(presentations, dts+int64(binary.BigEndian.Uint32(run[at+8:at+12]))-origin)
		dts += int64(binary.BigEndian.Uint32(run[at : at+4]))
	}
	return dts, presentations
}

func TestAlignVideoSlot(t *testing.T) {
	vide := make([]byte, 12)
	copy(vide[8:12], "vide")
	moov := mkbox("moov", mkbox("trak", bytes.Join([][]byte{tkhdV0(1),
		mkbox("mdia", bytes.Join([][]byte{mdhdV0(16000), mkbox("hdlr", vide)}, nil))}, nil)))
	segment := func(durations, offsets []uint32) []byte {
		return bytes.Join([][]byte{moov, mkbox("moof", mkbox("traf",
			bytes.Join([][]byte{tfhd(1), tfdtV1(0), trun(durations, offsets)}, nil)))}, nil)
	}
	// Millisecond source timestamps at 23.976 fps give 656/672-tick frames;
	// the muxer's guessed final duration leaves the run 16 ticks short.
	t.Run("shortfall", func(t *testing.T) {
		data := segment([]uint32{672, 656, 656}, []uint32{1328, 1328, 1328})
		if err := alignVideoSlot(data, 0, 2000.0/16000); err != nil {
			t.Fatal(err)
		}
		if sum, _ := videoTiming(data); sum != 2000 {
			t.Fatalf("durations sum to %d, want 2000", sum)
		}
	})
	// The next segment's keyframe, presented exactly at the slot end.
	t.Run("repeated keyframe", func(t *testing.T) {
		data := segment([]uint32{656, 656, 656, 656}, []uint32{1328, 1328, 1328, 1328})
		if err := alignVideoSlot(data, 0, 1968.0/16000); err == nil {
			t.Fatal("expected the repeated keyframe to be reported")
		}
	})
	// Stream-copied B-frames whose derived DTS opens with an oversized gap:
	// the frames are right but their durations overshoot the slot.
	t.Run("oversized gap", func(t *testing.T) {
		data := segment([]uint32{2000, 656, 656, 656}, []uint32{1328, 0, 0, 0})
		_, before := videoTiming(data)
		if err := alignVideoSlot(data, 0, 2656.0/16000); err != nil {
			t.Fatal(err)
		}
		sum, after := videoTiming(data)
		if sum != 2656 {
			t.Fatalf("durations sum to %d, want 2656", sum)
		}
		if fmt.Sprint(before) != fmt.Sprint(after) {
			t.Fatalf("presentation times moved: %v -> %v", before, after)
		}
	})
}
