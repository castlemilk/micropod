package main

import "golang.org/x/net/dns/dnsmessage"

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
