// Resolve the guest TX probe's CO-RE offsets and check its hook signatures against
// a saved kernel Image or raw BTF. This command never invokes the bpf syscall.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/btf"
)

type program struct {
	Section string   `json:"section"`
	Fixups  []string `json:"resolved_relocations"`
}

type result struct {
	Object   string              `json:"object_sha256"`
	Target   string              `json:"target_file_sha256"`
	BTF      string              `json:"target_btf_sha256"`
	Programs map[string]program  `json:"programs"`
	Hooks    map[string][]string `json:"target_signatures"`
}

// Archived arm64 Images embed a single BTF v1 header. Use the same extent
// checks as relaybench/socket_layout, including the contiguous string table.
func targetBTF(data []byte) ([]byte, error) {
	header := []byte{0x9f, 0xeb, 1, 0, 24, 0, 0, 0}
	i := bytes.Index(data, header)
	if i < 0 || bytes.Count(data, header) != 1 || len(data)-i < 24 {
		return nil, fmt.Errorf("expected one complete little-endian BTF v1 header")
	}
	blob := data[i:]
	field := func(i int) uint64 { return uint64(binary.LittleEndian.Uint32(blob[i:])) }
	end := 24 + field(16) + field(20)
	if field(8)+field(12) != field(16) || end > uint64(len(blob)) {
		return nil, fmt.Errorf("invalid BTF section lengths")
	}
	return blob[:end], nil
}

// The spelling of size_t differs between builds. Preserve widths, sign and
// pointer targets when checking argument slots used by the raw BPF context.
func typeName(t btf.Type) string {
	switch t := btf.UnderlyingType(t).(type) {
	case *btf.Void:
		return "void"
	case *btf.Pointer:
		return typeName(t.Target) + "*"
	case *btf.Struct:
		return "struct " + t.Name
	case *btf.Int:
		return fmt.Sprintf("%s%d", t.Encoding, t.Size*8)
	default:
		return fmt.Sprintf("%T", t)
	}
}

func signature(spec *btf.Spec, name string) ([]string, error) {
	t, err := spec.AnyTypeByName(name)
	if err != nil {
		return nil, err
	}
	switch f := btf.UnderlyingType(t).(type) {
	case *btf.Pointer: // btf_trace_* callback, including its private data argument.
		t = f.Target
	case *btf.Func:
		t = f.Type
	}
	proto, ok := btf.UnderlyingType(t).(*btf.FuncProto)
	if !ok {
		return nil, fmt.Errorf("%s has no function prototype", name)
	}
	types := []string{typeName(proto.Return)}
	for _, param := range proto.Params {
		types = append(types, typeName(param.Type))
	}
	return types, nil
}

func inspect(object, target []byte) (result, error) {
	r := result{Object: fmt.Sprintf("%x", sha256.Sum256(object)),
		Target: fmt.Sprintf("%x", sha256.Sum256(target)), Programs: map[string]program{}, Hooks: map[string][]string{}}
	blob, err := targetBTF(target)
	if err != nil {
		return r, err
	}
	r.BTF = fmt.Sprintf("%x", sha256.Sum256(blob))
	types, err := btf.LoadSpecFromReader(bytes.NewReader(blob))
	if err != nil {
		return r, err
	}
	src, err := ebpf.LoadCollectionSpecFromReader(bytes.NewReader(object))
	if err != nil {
		return r, err
	}
	const start = "btf_trace_net_dev_start_xmit"
	const end = "btf_trace_net_dev_xmit"
	wanted := map[string][]string{
		start: {"void", "void*", "struct sk_buff*", "struct net_device*"},
		end:   {"void", "void*", "struct sk_buff*", "signed32", "struct net_device*", "unsigned32"},
	}
	seen := map[string]bool{}
	for name, p := range src.Programs {
		var relos []*btf.CORERelocation
		for i := range p.Instructions {
			if relo := btf.CORERelocationMetadata(&p.Instructions[i]); relo != nil {
				relos = append(relos, relo)
			}
		}
		switch p.SectionName {
		case "raw_tp/net_dev_start_xmit":
			seen[start] = true
		case "raw_tp/net_dev_xmit":
			seen[end] = true
		case "fexit/tcp_sendmsg":
			wanted["tcp_sendmsg"] = []string{"signed32", "struct sock*", "struct msghdr*", "unsigned64"}
		default:
			return r, fmt.Errorf("unexpected probe section %s", p.SectionName)
		}
		fixups, err := btf.CORERelocate(relos, []*btf.Spec{types}, src.ByteOrder, src.Types.TypeID)
		if err != nil {
			return r, fmt.Errorf("%s: %w", name, err)
		}
		entry := program{Section: p.SectionName, Fixups: []string{}}
		for i, f := range fixups {
			if strings.HasSuffix(f.String(), "=poison") {
				return r, fmt.Errorf("%s: unavailable target for %s", name, relos[i])
			}
			entry.Fixups = append(entry.Fixups, fmt.Sprintf("%s: %s", relos[i], f.String()))
		}
		if len(fixups) == 0 {
			return r, fmt.Errorf("%s has no offset relocations", p.SectionName)
		}
		r.Programs[name] = entry
	}
	if !seen[start] || !seen[end] {
		return r, fmt.Errorf("missing one or both transmit raw tracepoints")
	}
	for hook, want := range wanted {
		got, err := signature(types, hook)
		if err != nil {
			return r, fmt.Errorf("%s: %w", hook, err)
		}
		if !slices.Equal(got, want) {
			return r, fmt.Errorf("%s signature %v, expected %v", hook, got, want)
		}
		r.Hooks[hook] = got
	}
	return r, nil
}

func run(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: corecheck GUEST_TX_OBJECT ARM64_IMAGE_OR_RAW_BTF")
	}
	object, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	target, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	r, err := inspect(object, target)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	return enc.Encode(r)
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
