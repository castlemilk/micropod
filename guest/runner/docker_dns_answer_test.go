package main

import (
	"bytes"
	"strings"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

// Mirror dnsReply's general packer, with the old append path for local answers.
func referenceServiceA(h dnsmessage.Header, q dnsmessage.Question, ip [4]byte) ([]byte, error) {
	reply := dnsmessage.Message{Header: h, Questions: []dnsmessage.Question{q}}
	reply.Answers = append(reply.Answers, dnsmessage.Resource{
		Header: dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 1},
		Body:   &dnsmessage.AResource{A: ip},
	})
	return reply.Pack()
}

func TestSingleServiceAWireMatchesGeneralPacker(t *testing.T) {
	maxName := strings.Repeat(strings.Repeat("a", 63)+".", 3) + strings.Repeat("b", 61) + "."
	ip := [4]byte{10, 90, 2, 3}
	for _, name := range []string{"db.", "Db.Service.", maxName, "."} {
		for _, typ := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeALL} {
			for _, recursive := range []bool{false, true} {
				q := dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: typ, Class: dnsmessage.ClassINET}
				h := dnsmessage.Header{ID: 539, Response: true, Authoritative: true, RecursionDesired: recursive, RecursionAvailable: !recursive}
				want, err := referenceServiceA(h, q, ip)
				if err != nil {
					t.Fatal(err)
				}
				got, err := packSingleServiceA(h, q, ip)
				if err != nil || !bytes.Equal(want, got) || len(got) > 512 {
					t.Fatalf("%s type %v: %x, want %x, err %v", name, typ, got, want, err)
				}
			}
		}
	}
}

var dnsAnswerBytes []byte

func BenchmarkPackSingleServiceA(b *testing.B) {
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("backend."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}
	h := dnsmessage.Header{ID: 123, Response: true, Authoritative: true, RecursionDesired: true}
	ip := [4]byte{10, 90, 0, 4}
	for _, impl := range []struct {
		name string
		pack func(dnsmessage.Header, dnsmessage.Question, [4]byte) ([]byte, error)
	}{{"general", referenceServiceA}, {"single", packSingleServiceA}} {
		b.Run(impl.name, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				var err error
				dnsAnswerBytes, err = impl.pack(h, q, ip)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
