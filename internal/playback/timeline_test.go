package playback

import (
	"bytes"
	"encoding/binary"
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
