package main

import (
	"errors"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
)

var serviceTGID, serviceNetNS, servicePort uint64
var servicePIDPath string

func addSenderFlags() {
	flag.Uint64Var(&serviceTGID, "service-tgid", 0, "service thread group ID in the guest initial PID namespace")
	flag.StringVar(&servicePIDPath, "service-pidfile", "", "existing OCI container init PID file, e.g. conmon --container-pidfile")
	flag.Uint64Var(&serviceNetNS, "service-netns", 0, "service socket network namespace inode")
	flag.Uint64Var(&servicePort, "service-port", 0, "service socket local TCP port in host byte order")
}

type senderObserver struct {
	id      senderIdentity
	task    *os.File
	pidfile string
	trace   link.Link
}

func prepareSender(spec *ebpf.CollectionSpec) (*senderObserver, error) {
	p := spec.Programs["service_send"]
	if len(spec.Programs) != 3 || p == nil || p.Type != ebpf.Tracing || p.AttachType != ebpf.AttachTraceFExit || p.AttachTo != "tcp_sendmsg" {
		return nil, errors.New("expected the queue observers and optional tcp_sendmsg exit program")
	}
	offsets := make([]uint32, len(serviceFields))
	for i := range offsets {
		offsets[i] = uint32(8 * i)
	}
	if err := checkMap(spec.Maps["service_counts"], ebpf.PerCPUArray, uint32(8*len(serviceFields)), serviceFields[:], offsets); err != nil {
		return nil, fmt.Errorf("service_counts: %w", err)
	}
	seen := make(map[string]bool, 4)
	flag.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "service-tgid", "service-pidfile", "service-netns", "service-port":
			seen[f.Name] = true
		}
	})
	if len(seen) == 0 {
		// Skip fexit target resolution and verifier prerequisites in queue-only mode.
		delete(spec.Programs, "service_send")
		delete(spec.Maps, "service_counts")
		return nil, nil
	}
	if seen["service-tgid"] == seen["service-pidfile"] || (serviceTGID > 0) == (servicePIDPath != "") || serviceTGID > math.MaxInt32 ||
		serviceNetNS == 0 || serviceNetNS > math.MaxUint32 || servicePort == 0 || servicePort > math.MaxUint16 {
		return nil, errors.New("specify exactly one service TGID or container PID file, plus a positive netns inode and TCP port")
	}
	tgid := uint32(serviceTGID)
	if servicePIDPath != "" {
		var err error
		if tgid, err = servicePIDFile(servicePIDPath); err != nil {
			return nil, err
		}
	}
	// BPF's current_pid_tgid uses initial-namespace IDs. Verify that the
	// procfs mount exposes those same IDs (Linux UAPI PID_NS_INIT_INO).
	pidNamespace, err := os.Readlink("/proc/1/ns/pid")
	if err != nil || pidNamespace != "pid:[4026531836]" {
		return nil, errors.New("initial guest PID namespace procfs required")
	}
	f, err := os.Open(filepath.Join("/proc", strconv.FormatUint(uint64(tgid), 10)))
	if err != nil {
		return nil, err
	}
	s := &senderObserver{task: f, pidfile: servicePIDPath}
	id, err := readSender(s.taskPath(), tgid, uint32(serviceNetNS), uint32(servicePort))
	if err != nil {
		f.Close()
		return nil, err
	}
	s.id = id
	return s, nil
}

func (s *senderObserver) taskPath() string {
	return filepath.Join("/proc/self/fd", strconv.Itoa(int(s.task.Fd())))
}

func (s *senderObserver) identity() any {
	if s == nil {
		return nil
	}
	return s.id
}

func (s *senderObserver) configure(c *config) {
	if s != nil {
		c.ServiceTGID, c.ServiceNetNS, c.ServicePort = s.id.TGID, s.id.NetNS, s.id.Port
	}
}

func (s *senderObserver) attach(coll *ebpf.Collection) error {
	if s == nil {
		return nil
	}
	var err error
	s.trace, err = link.AttachTracing(link.TracingOptions{Program: coll.Programs["service_send"]})
	return err
}

// close() detaches the hook. Keep the original process directory open until
// report() has verified identity, so a recycled PID cannot redirect the reads.
func (s *senderObserver) close() error {
	if s == nil || s.trace == nil {
		return nil
	}
	err := s.trace.Close()
	s.trace = nil
	return err
}

func (s *senderObserver) release() {
	if s != nil && s.task != nil {
		s.task.Close()
		s.task = nil
	}
}

func (s *senderObserver) report(coll *ebpf.Collection) (any, bool, error) {
	if s == nil {
		return nil, true, nil
	}
	var rows []serviceCounts
	if err := coll.Maps["service_counts"].Lookup(uint32(0), &rows); err != nil {
		return nil, false, err
	}
	totals, complete, err := summarizeService(rows)
	idErr := verifySender(s.taskPath(), s.id, s.pidfile)
	return totals, complete && idErr == nil && err == nil, errors.Join(err, idErr)
}
