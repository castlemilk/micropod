package main

import (
	"encoding/json"
	"maps"
	"testing"
)

func TestDockerPortSummaryWireShape(t *testing.T) {
	published := portMap{
		"8080/tcp": {{HostIP: "127.0.0.1", HostPort: "49153"}, {HostIP: "127.0.0.1", HostPort: "49152"}},
		"8081/tcp": {{HostIP: "127.0.0.1", HostPort: "49154"}},
		"9000/tcp": nil,
	}
	exposed := map[string]struct{}{"8080": {}, "8080/tcp": {}, "53/udp": {}, "123/sctp": {}}
	effective := published.withExposed(exposed)
	body, err := json.Marshal(effective.summary())
	if err != nil {
		t.Fatal(err)
	}
	want := `[{"PrivatePort":53,"Type":"udp"},` +
		`{"PrivatePort":123,"Type":"sctp"},` +
		`{"IP":"127.0.0.1","PrivatePort":8080,"PublicPort":49152,"Type":"tcp"},` +
		`{"IP":"127.0.0.1","PrivatePort":8080,"PublicPort":49153,"Type":"tcp"},` +
		`{"IP":"127.0.0.1","PrivatePort":8081,"PublicPort":49154,"Type":"tcp"},` +
		`{"PrivatePort":9000,"Type":"tcp"}]`
	if string(body) != want {
		t.Fatalf("port list = %s, want %s", body, want)
	}
	body, err = json.Marshal(effective)
	if err != nil {
		t.Fatal(err)
	}
	want = `{"123/sctp":null,"53/udp":null,` +
		`"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"49153"},{"HostIp":"127.0.0.1","HostPort":"49152"}],` +
		`"8081/tcp":[{"HostIp":"127.0.0.1","HostPort":"49154"}],"9000/tcp":null}`
	if string(body) != want {
		t.Fatalf("inspect port map = %s, want %s", body, want)
	}
	body, err = json.Marshal(portMap(nil).withExposed(nil))
	if err != nil || string(body) != `{}` {
		t.Fatalf("inspect for no ports = %s, %v, want {}", body, err)
	}
}

func TestMergeImageExposedPorts(t *testing.T) {
	caller := map[string]struct{}{"9000/tcp": {}, "8080/tcp": {}}
	info := `{"chainID":"sha256:fixture","imageSpec":{"architecture":"arm64","config":{
		"ExposedPorts":{"8080":{},"8081/tcp":{},"5353/udp":{},"invalid":{}}
	}}}`
	want := map[string]struct{}{"9000/tcp": {}, "8080/tcp": {}, "8081/tcp": {}, "5353/udp": {}}
	if got := mergeImageExposedPorts(caller, info); !maps.Equal(got, want) {
		t.Fatalf("merged exposures = %v, want %v", got, want)
	}
	if len(caller) != 2 {
		t.Fatalf("caller exposures were modified: %v", caller)
	}
	for _, info := range []string{"", `{}`, `malformed optional runtime info`} {
		if got := mergeImageExposedPorts(caller, info); !maps.Equal(got, caller) {
			t.Fatalf("optional image info %q changed exposures: %v", info, got)
		}
	}
}
