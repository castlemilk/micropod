package main

import (
	"errors"
	"math"
	"net/netip"

	"golang.org/x/net/dns/dnsmessage"
)

// A question-only response has no later name that could reference the first.
func packServiceQuestion(header dnsmessage.Header, q dnsmessage.Question) ([]byte, error) {
	out := dnsmessage.NewBuilder(make([]byte, 0, 12+int(q.Name.Length)+1+4), header)
	if err := out.StartQuestions(); err != nil {
		return nil, err
	}
	if err := out.Question(q); err != nil {
		return nil, err
	}
	return out.Finish()
}

// A single compressed IPv4 answer always fits the original 512-byte UDP limit.
// Size the reply for its actual name and construct the one resource directly.
func packSingleServiceA(header dnsmessage.Header, question dnsmessage.Question, address [4]byte) ([]byte, error) {
	body := dnsmessage.AResource{A: address}
	reply := dnsmessage.Message{
		Header:    header,
		Questions: []dnsmessage.Question{question},
		Answers: []dnsmessage.Resource{{
			Header: dnsmessage.ResourceHeader{Name: question.Name, Class: dnsmessage.ClassINET, TTL: 1},
			Body:   &body,
		}},
	}
	// Header, encoded QNAME (including root), QTYPE/QCLASS, compressed A RR.
	capacity := 12 + int(question.Name.Length) + 1 + 4 + 16
	return reply.AppendPack(make([]byte, 0, capacity))
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
	if network != "udp" {
		return math.MaxUint16
	}
	question, record := serviceAnswerLengths(&q.Name)
	limit := 512
	// Beyond the worker's maximum EDNS size, no option can make this answer fit.
	if hasAdditional && count <= (4096-question)/record {
		limit = serviceUDPLimit(parser)
	}
	return (limit - question) / record
}

func packServiceAddresses(header dnsmessage.Header, q dnsmessage.Question, ips []netip.Addr, count int) ([]byte, error) {
	if count > math.MaxUint16 {
		return nil, errors.New("too many DNS answers")
	}
	if len(ips) < count {
		header.Truncated = true
		return packServiceQuestion(header, q)
	}
	question, record := serviceAnswerLengths(&q.Name)
	size := question + record*len(ips)
	out := dnsmessage.NewBuilder(make([]byte, 0, size), header)
	out.EnableCompression()
	if err := out.StartQuestions(); err != nil {
		return nil, err
	}
	if err := out.Question(q); err != nil {
		return nil, err
	}
	if err := out.StartAnswers(); err != nil {
		return nil, err
	}
	rr := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 1}
	for _, ip := range ips {
		if err := out.AResource(rr, dnsmessage.AResource{A: ip.As4()}); err != nil {
			return nil, err
		}
	}
	return out.Finish()
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
