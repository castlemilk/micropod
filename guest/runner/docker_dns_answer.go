package main

import (
	"encoding/binary"
	"errors"
	"math"
	"net/netip"

	"golang.org/x/net/dns/dnsmessage"
)

// A question-only response has no later name that could reference the first.
func packServiceQuestion(header dnsmessage.Header, q dnsmessage.Question) ([]byte, error) {
	return packServiceQuestionInto(nil, header, q, 0)
}

func packServiceQuestionInto(dst []byte, header dnsmessage.Header, q dnsmessage.Question, answerBytes int) ([]byte, error) {
	need := 12 + int(q.Name.Length) + 1 + 4 + answerBytes
	if cap(dst) < need {
		dst = make([]byte, 0, need)
	} else {
		dst = dst[:0]
	}
	out := dnsmessage.NewBuilder(dst, header)
	if err := out.StartQuestions(); err != nil {
		return nil, err
	}
	if err := out.Question(q); err != nil {
		return nil, err
	}
	return out.Finish()
}

// The sole answer always has the same owner as the question. Its name is
// either the literal root or a compression pointer to the QNAME at offset 12.
func packSingleServiceA(header dnsmessage.Header, q dnsmessage.Question, address [4]byte) ([]byte, error) {
	return packSingleServiceAInto(nil, header, q, address)
}

func packSingleServiceAInto(dst []byte, header dnsmessage.Header, q dnsmessage.Question, address [4]byte) ([]byte, error) {
	wire, err := packServiceQuestionInto(dst, header, q, 16)
	if err != nil {
		return nil, err
	}
	binary.BigEndian.PutUint16(wire[6:8], 1) // ANCOUNT
	return appendServiceA(wire, address), nil
}

// Every answer has the same owner as the question at offset 12.
func appendServiceA(wire []byte, address [4]byte) []byte {
	if wire[12] == 0 {
		wire = append(wire, 0)
	} else {
		wire = append(wire, 0xc0, 12)
	}
	wire = binary.BigEndian.AppendUint16(wire, uint16(dnsmessage.TypeA))
	wire = binary.BigEndian.AppendUint16(wire, uint16(dnsmessage.ClassINET))
	wire = binary.BigEndian.AppendUint32(wire, 1) // TTL
	wire = binary.BigEndian.AppendUint16(wire, uint16(len(address)))
	return append(wire, address[:]...)
}

// Compression makes each answer a pointer to the question plus its IPv4
// resource, except that the root has a shorter literal encoding.
func serviceAnswerLengths(name *dnsmessage.Name) (question, record int) {
	if name.Length == 1 && name.Data[0] == '.' {
		return 17, 15
	}
	return 17 + int(name.Length), 16
}

func serviceAnswerLimit(q *dnsmessage.Question, network string, parser *dnsmessage.Parser, hasAdditional bool, count int) int {
	question, record := serviceAnswerLengths(&q.Name)
	if network != "udp" {
		// The two-byte TCP length counts the entire DNS message.
		return (math.MaxUint16 - question) / record
	}
	limit := 512
	// Beyond the worker's maximum EDNS size, no option can make this answer fit.
	if hasAdditional && count <= (4096-question)/record {
		limit = serviceUDPLimit(parser)
	}
	return (limit - question) / record
}

func packServiceAddresses(header dnsmessage.Header, q dnsmessage.Question, ips []netip.Addr, count int) ([]byte, error) {
	return packServiceAddressesInto(nil, header, q, ips, count)
}

func packServiceAddressesInto(dst []byte, header dnsmessage.Header, q dnsmessage.Question, ips []netip.Addr, count int) ([]byte, error) {
	if count > math.MaxUint16 || len(ips) > math.MaxUint16 {
		return nil, errors.New("too many DNS answers")
	}
	if len(ips) < count {
		header.Truncated = true
		return packServiceQuestionInto(dst, header, q, 0)
	}
	_, record := serviceAnswerLengths(&q.Name)
	wire, err := packServiceQuestionInto(dst, header, q, record*len(ips))
	if err != nil {
		return nil, err
	}
	binary.BigEndian.PutUint16(wire[6:8], uint16(len(ips)))
	for _, ip := range ips {
		wire = appendServiceA(wire, ip.As4())
	}
	return wire, nil
}

func serviceUDPLimit(parser *dnsmessage.Parser) int {
	if parser.SkipAllAnswers() == nil && parser.SkipAllAuthorities() == nil {
		for {
			h, err := parser.AdditionalHeader()
			if err != nil {
				break
			}
			if h.Type == dnsmessage.TypeOPT {
				return min(4096, max(512, int(h.Class)))
			}
			if parser.SkipAdditional() != nil {
				break
			}
		}
	}
	return 512
}
