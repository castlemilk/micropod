package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"net/netip"
	"strings"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

// The offline comparison driver records these same observations from both
// builds, including individual failing cases on the older implementation.
func logDNSFrame(t *testing.T, observation map[string]any) {
	t.Helper()
	wire, err := json.Marshal(observation)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("frame_observation %s", wire)
}

func TestServiceTCPFrameBudget(t *testing.T) {
	longName := strings.Repeat(strings.Repeat("x", 63)+".", 3) + strings.Repeat("y", 61) + "."
	for _, tc := range []struct{ kind, name string }{
		{"root", "."}, {"ordinary", "Replica.Local."}, {"longest", longName},
	} {
		q := dnsmessage.Question{Name: dnsmessage.MustNewName(tc.name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}
		request := dnsmessage.Message{Header: dnsmessage.Header{ID: 0x6423, RecursionDesired: true}, Questions: []dnsmessage.Question{q}}
		packet, err := request.Pack()
		if err != nil {
			t.Fatal(err)
		}
		reply := dnsmessage.Message{Header: dnsmessage.Header{ID: request.ID, Response: true, Authoritative: true, RecursionDesired: true}, Questions: []dnsmessage.Question{q}}
		rr := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 1}
		reply.Answers = []dnsmessage.Resource{{Header: rr, Body: &dnsmessage.AResource{}}}
		one, err := reply.Pack()
		if err != nil {
			t.Fatal(err)
		}
		// Derive the capacity independently from the reference library's
		// encoded question and first answer, including root-name compression.
		perAnswer := len(one) - len(packet)
		fits := (math.MaxUint16 - len(packet)) / perAnswer
		for _, count := range []int{fits, fits + 1} {
			t.Run(fmt.Sprintf("%s/%d", tc.kind, count), func(t *testing.T) {
				ips := make([]netip.Addr, count)
				answers := make([]dnsmessage.Resource, count)
				for i := range ips {
					ip := [4]byte{10, 2, byte(i >> 8), byte(i)}
					ips[i] = netip.AddrFrom4(ip)
					answers[i] = dnsmessage.Resource{Header: rr, Body: &dnsmessage.AResource{A: ip}}
				}
				network := &workerNetwork{Internal: true}
				network.services.records = map[string][]netip.Addr{strings.ToLower(strings.TrimSuffix(tc.name, ".")): ips}
				wire := new(dockerEngine).dnsReply(context.Background(), network, nil, packet, "tcp")
				reference := reply
				reference.Answers = answers
				if count > fits {
					reference.Truncated = true
					reference.Answers = nil
				}
				want, err := reference.Pack()
				if err != nil {
					t.Fatal(err)
				}
				var frame bytes.Buffer
				if err := sendDNS(&frame, wire); err != nil {
					t.Fatal(err)
				}
				if len(wire) < 12 || frame.Len() < 2 {
					t.Fatal("missing DNS frame")
				}
				declared := int(binary.BigEndian.Uint16(frame.Bytes()))
				logDNSFrame(t, map[string]any{
					"name": tc.kind, "answers_offered": count, "max_fitting_answers": fits,
					"full_message_bytes": len(packet) + perAnswer*count, "wire_bytes": len(wire),
					"prefix_bytes_declared": declared, "answers_sent": binary.BigEndian.Uint16(wire[6:8]),
					"truncated": wire[2]&2 != 0, "wire_sha256": fmt.Sprintf("%x", sha256.Sum256(wire)),
				})
				if !bytes.Equal(wire, want) || len(wire) != declared {
					t.Fatal("framed DNS reply differs from the in-budget reference encoding")
				}
				body, err := readDNS(&frame)
				if err != nil || !bytes.Equal(body, want) || frame.Len() != 0 {
					t.Fatal("failed to consume exactly one DNS frame", err)
				}
			})
		}
	}
}

func TestSendDNSFrameLimitBeforeWriting(t *testing.T) {
	for _, size := range []int{math.MaxUint16, 1 << 16} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			var dst bytes.Buffer
			err := sendDNS(&dst, make([]byte, size))
			logDNSFrame(t, map[string]any{"direct_send_bytes": size, "writer_bytes": dst.Len(), "rejected": err != nil})
			if size == math.MaxUint16 {
				if err != nil || dst.Len() != size+2 || int(binary.BigEndian.Uint16(dst.Bytes())) != size {
					t.Fatal("maximum TCP frame changed")
				}
			} else if err == nil || dst.Len() != 0 {
				t.Fatal("oversized message must fail before any write")
			}
		})
	}
}

func TestServiceTCPUnrepresentableAnswerCount(t *testing.T) {
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("Many."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}
	m := dnsmessage.Message{Questions: []dnsmessage.Question{q}}
	request, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	network := &workerNetwork{Internal: true}
	ips := make([]netip.Addr, 1<<16)
	for i := range ips {
		ips[i] = netip.AddrFrom4([4]byte{10, 1, byte(i >> 8), byte(i)})
	}
	network.services.records = map[string][]netip.Addr{"many": ips}
	wire := new(dockerEngine).dnsReply(context.Background(), network, nil, request, "tcp")
	logDNSFrame(t, map[string]any{"unrepresentable_answer_count": len(ips), "reply_absent": wire == nil})
	if wire != nil {
		t.Fatal("unrepresentable answer count was accepted")
	}
}
