package main

import "testing"

func TestParseCgroupKVAndPSI(t *testing.T) {
	cpuStat := "usage_usec 125000\nuser_usec 90000\nsystem_usec 35000\nnr_periods 100\nnr_throttled 7\nthrottled_usec 42000\n"
	kv := parseCgroupKV(cpuStat)
	if kv["user_usec"] != 90000 || kv["system_usec"] != 35000 || kv["nr_throttled"] != 7 || kv["throttled_usec"] != 42000 {
		t.Fatalf("unexpected cpu.stat parse: %+v", kv)
	}

	memEvents := "low 0\nhigh 3\nmax 2\noom 1\noom_kill 1\n"
	mev := parseCgroupKV(memEvents)
	if mev["oom"] != 1 || mev["oom_kill"] != 1 || mev["high"] != 3 || mev["max"] != 2 {
		t.Fatalf("unexpected memory.events parse: %+v", mev)
	}

	psi := "some avg10=0.12 avg60=0.05 avg300=0.01 total=987654\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=123\n"
	got, ok := parsePSISomeTotalUsec(psi)
	if !ok || got != 987654 {
		t.Fatalf("unexpected PSI parse: ok=%v got=%d", ok, got)
	}
}
