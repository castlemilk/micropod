package main

import (
	"encoding/binary"
	"errors"
	"slices"
	"strings"
	"testing"
)

func superblock(blocks uint64, logSize uint32, sixtyFour bool) []byte {
	sb := make([]byte, 1024)
	binary.LittleEndian.PutUint16(sb[0x38:], 0xEF53)
	binary.LittleEndian.PutUint32(sb[0x04:], uint32(blocks))
	binary.LittleEndian.PutUint32(sb[0x18:], logSize)
	if sixtyFour {
		binary.LittleEndian.PutUint32(sb[0x60:], 0x80)
		binary.LittleEndian.PutUint32(sb[0x150:], uint32(blocks>>32))
	}
	return sb
}

func TestParseExt4Superblock(t *testing.T) {
	g, err := parseExt4Superblock(superblock(8421376, 2, false))
	if err != nil || g.blocks != 8421376 || g.blockSize != 4096 || g.bytes() != 8421376*4096 {
		t.Fatalf("geometry %+v %v", g, err)
	}
	g, err = parseExt4Superblock(superblock(1<<33, 2, true))
	if err != nil || g.blocks != 1<<33 {
		t.Fatalf("64bit geometry %+v %v", g, err)
	}
	bad := superblock(1, 2, false)
	bad[0x38] = 0
	if _, err := parseExt4Superblock(bad); err == nil {
		t.Fatal("a superblock without the ext4 magic was read")
	}
}

// A grow replays the journal, checks, resizes and checks again, in that
// order; a check that finds what it cannot fix, a failed resize or a check
// after it that is not clean fails the grow, and a device smaller than its
// filesystem is never touched.
func TestDiskGrowerSteps(t *testing.T) {
	type outcome struct {
		size          uint64
		fsck, resize  int
		after         int
		wantErr       string
		wantSteps     []string
		blocksBefore  uint64
		blocksGrownTo uint64
	}
	for name, tc := range map[string]outcome{
		"grows": {size: 16 << 30, blocksBefore: 1 << 20, blocksGrownTo: 4 << 20,
			wantSteps: []string{"replay", "e2fsck -f -y /dev/vdb", "resize2fs /dev/vdb", "e2fsck -f -n /dev/vdb"}},
		"fixed before": {size: 16 << 30, fsck: 1, blocksBefore: 1 << 20, blocksGrownTo: 4 << 20,
			wantSteps: []string{"replay", "e2fsck -f -y /dev/vdb", "resize2fs /dev/vdb", "e2fsck -f -n /dev/vdb"}},
		"unfixable": {size: 16 << 30, fsck: 4, blocksBefore: 1 << 20, wantErr: "e2fsck before the grow",
			wantSteps: []string{"replay", "e2fsck -f -y /dev/vdb"}},
		"resize fails": {size: 16 << 30, resize: 1, blocksBefore: 1 << 20, wantErr: "resize2fs",
			wantSteps: []string{"replay", "e2fsck -f -y /dev/vdb", "resize2fs /dev/vdb"}},
		"unclean after": {size: 16 << 30, after: 4, blocksBefore: 1 << 20, blocksGrownTo: 4 << 20, wantErr: "after the grow",
			wantSteps: []string{"replay", "e2fsck -f -y /dev/vdb", "resize2fs /dev/vdb", "e2fsck -f -n /dev/vdb"}},
		"smaller device": {size: 1 << 30, blocksBefore: 1 << 20, wantErr: "never shrunk"},
	} {
		t.Run(name, func(t *testing.T) {
			var steps []string
			blocks := tc.blocksBefore
			g := diskGrower{dev: "/dev/vdb", tools: "/opt/micropod-oci",
				geometry: func(string) (ext4Geometry, error) { return ext4Geometry{blocks: blocks, blockSize: 4096}, nil },
				size:     func(string) (uint64, error) { return tc.size, nil },
				replay:   func(string) error { steps = append(steps, "replay"); return nil },
				run: func(tool string, args ...string) (int, error) {
					step := tool + " " + strings.Join(args, " ")
					steps = append(steps, step)
					switch {
					case tool == "resize2fs":
						if tc.resize == 0 {
							blocks = tc.blocksGrownTo
						}
						return tc.resize, nil
					case slices.Contains(args, "-n"):
						return tc.after, nil
					default:
						return tc.fsck, nil
					}
				},
				log: func(string, ...any) {}}
			before, after, err := g.grow()
			if tc.wantErr == "" && err != nil || tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)) {
				t.Fatalf("err %v, want %q", err, tc.wantErr)
			}
			if !slices.Equal(steps, tc.wantSteps) {
				t.Fatalf("steps %q, want %q", steps, tc.wantSteps)
			}
			if err == nil && (before.blocks != tc.blocksBefore || after.blocks != tc.blocksGrownTo) {
				t.Fatalf("before %d after %d", before.blocks, after.blocks)
			}
		})
	}
	g := diskGrower{dev: "/dev/vdb", size: func(string) (uint64, error) { return 0, errors.New("no device") }}
	if _, _, err := g.grow(); err == nil {
		t.Fatal("a missing device was grown")
	}
}
