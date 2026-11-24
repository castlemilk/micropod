package main

import (
	"fmt"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/btf"
)

// Validate field offsets as well as sizes. A stale object must not silently
// label a different per-CPU counter as accepted or charged bytes.
func checkMap(s *ebpf.MapSpec, typ ebpf.MapType, size uint32, fields []string, offsets []uint32) error {
	if s == nil || s.Type != typ || s.KeySize != 4 || s.ValueSize != size || s.MaxEntries != 1 {
		return fmt.Errorf("unexpected map shape (want type %s and %d-byte value)", typ, size)
	}
	v, ok := btf.UnderlyingType(s.Value).(*btf.Struct)
	if !ok || len(v.Members) != len(fields) {
		return fmt.Errorf("unexpected map BTF value")
	}
	for i, f := range v.Members {
		if f.Name != fields[i] || uint32(f.Offset) != 8*offsets[i] || f.BitfieldSize != 0 {
			return fmt.Errorf("unexpected BTF field %q at bit %d", f.Name, f.Offset)
		}
	}
	return nil
}

func checkSpec(s *ebpf.CollectionSpec) error {
	for p, trace := range map[string]string{"tx_enter": "net_dev_start_xmit", "tx_exit": "net_dev_xmit"} {
		prog := s.Programs[p]
		if prog == nil || prog.Type != ebpf.RawTracepoint || prog.AttachTo != trace {
			return fmt.Errorf("missing or incompatible raw tracepoint %s", p)
		}
	}
	configFields := []string{"start_ns", "end_ns", "netns_inum", "ifindex", "queue", "service_tgid", "service_netns", "service_port", "service_pad"}
	if err := checkMap(s.Maps["config"], ebpf.Array, 48, configFields, []uint32{0, 8, 16, 20, 24, 28, 32, 36, 40}); err != nil {
		return fmt.Errorf("config: %w", err)
	}
	offsets := make([]uint32, len(counterNames))
	for i := range offsets {
		offsets[i] = uint32(8 * i)
	}
	if err := checkMap(s.Maps["counts"], ebpf.PerCPUArray, uint32(8*len(counterNames)), counterNames[:], offsets); err != nil {
		return fmt.Errorf("counts: %w", err)
	}
	return nil
}
