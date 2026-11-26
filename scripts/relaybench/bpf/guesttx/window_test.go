package main

import (
	"context"
	"encoding/binary"
	"math"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/cilium/ebpf"
)

func TestCPUAccounting(t *testing.T) {
	c, err := aggregate([]counts{{2, 200, 2, 1, 1, 0, 90, 0, 0, 0}, {3, 300, 3, 2, 0, 1, 0, 0, 0, 0}})
	if err != nil || !matched(c) || c["attempted_bytes"] != 500 || c["dql_charged_bytes"] != 90 {
		t.Fatalf("unexpected aggregate: %v %v", c, err)
	}
	for _, field := range []string{"completed_calls", "tx_ok", "read_errors", "overlaps", "boundary_crossings"} {
		c[field]++
		if matched(c) {
			t.Fatalf("accepted corrupt %s", field)
		}
		c[field]--
	}
	if matched(nil) {
		t.Fatal("missing events")
	}
	if _, err := aggregate(nil); err == nil {
		t.Fatal("absent CPUs")
	}
	if _, err := aggregate([]counts{{math.MaxUint64}, {1}}); err == nil {
		t.Fatal("wrapped counter")
	}
}

func TestControllerEnd(t *testing.T) {
	for input, want := range map[string]string{"stop\n": "stop", "": "stdin_eof", "stop": "invalid_stop", "hello\n": "invalid_stop", strings.Repeat("x", 100): "invalid_stop"} {
		if got := waitEnd(context.Background(), strings.NewReader(input), time.Second); got != want {
			t.Fatalf("%q: got %s want %s", input, got, want)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := waitEnd(ctx, nil, time.Second); got != "signal" {
		t.Fatal(got)
	}
	if got := waitEnd(context.Background(), nil, time.Millisecond); got != "timeout" {
		t.Fatal(got)
	}
}

func TestConfigWireLayout(t *testing.T) {
	cfg := config{StartNS: 1, EndNS: 2, NetNS: 3, Ifindex: 4, Queue: 5, ServiceTGID: 6, ServiceNetNS: 7, ServicePort: 8}
	wire, err := binary.Append(nil, binary.LittleEndian, cfg)
	if err != nil || len(wire) != 48 {
		t.Fatalf("wire size %d error %v", len(wire), err)
	}
	var fields []uint32
	for i := 16; i < len(wire); i += 4 {
		fields = append(fields, binary.LittleEndian.Uint32(wire[i:]))
	}
	if !reflect.DeepEqual(fields, []uint32{3, 4, 5, 6, 7, 8, 0, 0}) {
		t.Fatal(fields)
	}
}

func TestCompiledObjectABI(t *testing.T) {
	obj := os.Getenv("GUEST_TX_TEST_OBJECT")
	if obj == "" {
		t.Skip("set GUEST_TX_TEST_OBJECT to the compiled guest_tx.bpf.o")
	}
	s, err := ebpf.LoadCollectionSpec(obj)
	if err != nil {
		t.Fatal(err)
	}
	if err := checkSpec(s); err != nil {
		t.Fatal(err)
	}
	s.Maps["counts"].ValueSize -= 8
	if err := checkSpec(s); err == nil {
		t.Fatal("accepted truncated counter map")
	}
}
