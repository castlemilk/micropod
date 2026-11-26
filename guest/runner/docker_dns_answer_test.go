package main

import (
	"bytes"
	"strings"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

func TestQuestionOnlyReplyMatchesMessageEncoding(t *testing.T) {
	for _, name := range []string{".", "Db.", "A.a.a.", strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61) + "."} {
		q := dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeAAAA, Class: dnsmessage.ClassINET}
		for _, code := range []dnsmessage.RCode{dnsmessage.RCodeSuccess, dnsmessage.RCodeNameError, dnsmessage.RCodeServerFailure} {
			h := dnsmessage.Header{ID: 42, Response: true, Authoritative: code != dnsmessage.RCodeServerFailure, RecursionDesired: true, RecursionAvailable: true, RCode: code}
			ref := dnsmessage.Message{Header: h, Questions: []dnsmessage.Question{q}}
			want, err := ref.Pack()
			if err != nil {
				t.Fatal(err)
			}
			got, err := packServiceQuestion(h, q)
			if err != nil || !bytes.Equal(want, got) {
				t.Fatalf("question-only %q %s: %x, want %x (%v)", name, code, got, want, err)
			}
		}
	}
}

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

func TestSingleServiceAQuestionClassAndInvalidName(t *testing.T) {
	for _, name := range []string{"", ".", "Svc.", "missing-root", "two..dots.", strings.Repeat("x", 64) + "."} {
		q := dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeALL, Class: dnsmessage.ClassCHAOS}
		h := dnsmessage.Header{ID: 0xffff, Response: true, RecursionDesired: true}
		ip := [4]byte{255, 0, 255, 0}
		want, wantErr := referenceServiceA(h, q, ip)
		got, err := packSingleServiceA(h, q, ip)
		if (err != nil) != (wantErr != nil) || !bytes.Equal(got, want) {
			t.Fatalf("question %q: packed %x (%v), want %x (%v)", name, got, err, want, wantErr)
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
	b.Run("single-into-reused", func(b *testing.B) {
		buf := make([]byte, 0, 512)
		b.ReportAllocs()
		for b.Loop() {
			var err error
			dnsAnswerBytes, err = packSingleServiceAInto(buf[:0], h, q, ip)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}
