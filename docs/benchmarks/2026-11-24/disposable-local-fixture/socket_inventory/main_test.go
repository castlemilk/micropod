package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

const header = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
const header6 = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
const counters = " 00000000:00000000 00:00000000 00000000 0 0 571 3 0000000000000000 20 4 1 10 -1\n"
const v4 = "   1: 0200580A:1F90 0100A8C0:C351 01"
const v6mapped = "   5: 0000000000000000FFFF00000200580A:1F90 0000000000000000FFFF00000100A8C0:C350 01"

func TestEstablishedServiceOnly(t *testing.T) {
	// Explicit listening and client-side rows do not belong to the observed service tuple.
	table4 := header + v4 + counters +
		" 2: 00000000:1F90 00000000:0000 0A" + counters +
		" 3: 0100A8C0:C351 0200580A:1F90 01" + counters +
		" 4: 0200580A:1F90 0100A8C0:C354 06" + counters
	got, err := collect(strings.NewReader(table4), strings.NewReader(header6+v6mapped+counters))
	want := []connection{{"10.88.0.2", 8080, "192.168.0.1", 50000}, {"10.88.0.2", 8080, "192.168.0.1", 50001}}
	if err != nil || got.Source != "proc_net_tcp" || !reflect.DeepEqual(got.Connections, want) {
		t.Fatalf("connections = %+v, err = %v", got, err)
	}
}

func TestIPv6AndEmpty(t *testing.T) {
	const v6 = " 0: B80D0120000000000000000002000000:1F90 B80D0120000000000000000001000000:000A 01"
	got, err := collect(strings.NewReader(header), strings.NewReader(header6+v6+counters))
	if err != nil || !reflect.DeepEqual(got.Connections, []connection{{"2001:db8::2", 8080, "2001:db8::1", 10}}) {
		t.Fatalf("ipv6 = %+v, err = %v", got, err)
	}
	got, err = collect(strings.NewReader(header), strings.NewReader(header6))
	raw, jsonErr := json.Marshal(got)
	if err != nil || jsonErr != nil || string(raw) != `{"source":"proc_net_tcp","connections":[]}` {
		t.Fatalf("empty = %s, err = %v, %v", raw, err, jsonErr)
	}
}

func TestMalformedOrIncompleteInputFailsWholeObservation(t *testing.T) {
	for name, tail := range map[string]string{
		"truncated line":        strings.TrimSuffix(v6mapped+counters, "\n"),
		"missing counters":      v6mapped + "\n",
		"wrong remote encoding": strings.Replace(v6mapped, "C350", "GGGG", 1) + counters,
		"wrong address family":  v4 + counters,
		"unknown state syntax":  strings.TrimSuffix(v6mapped, "01") + "ZZ" + counters,
		"invalid counter":       v6mapped + strings.Replace(counters, " 571 ", " ??? ", 1),
		"broken sender port":    strings.Replace(v6mapped, ":1F90", ":FFF", 1) + counters,
		"invalid row index":     strings.Replace(v6mapped, "5:", "x:", 1) + counters,
		"unspecified peer":      strings.Replace(v6mapped, "FFFF00000100A8C0", "0000000000000000", 1) + counters,
		"zero peer port":        strings.Replace(v6mapped, ":C350", ":0000", 1) + counters,
		"duplicate normalized":  strings.Replace(v6mapped, ":C350", ":C351", 1) + counters,
	} {
		t.Run(name, func(t *testing.T) {
			got, err := collect(strings.NewReader(header+v4+counters), strings.NewReader(header6+tail))
			if err == nil || got.Connections != nil || got.Source != "" {
				t.Fatalf("partial evidence escaped: %+v, err = %v", got, err)
			}
		})
	}
	for _, invalid := range []string{"", "wrong header\n", strings.TrimSuffix(header, "\n")} {
		if _, err := collect(strings.NewReader(invalid), strings.NewReader(header6)); err == nil {
			t.Fatalf("accepted header %q", invalid)
		}
	}
}
