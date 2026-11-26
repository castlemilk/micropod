package main

import (
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func TestPollReportsDisconnection(t *testing.T) {
	for _, tc := range []struct {
		name   string
		events int16
		err    error
		want   bool
	}{
		{name: "interrupted", err: unix.EINTR},
		{name: "try again", err: unix.EAGAIN},
		{name: "local allocation failure", err: unix.ENOMEM},
		{name: "idle"},
		{name: "readable", events: unix.POLLIN},
		{name: "write half closed", events: unix.POLLRDHUP},
		{name: "hangup", events: unix.POLLHUP, want: true},
		{name: "socket error", events: unix.POLLERR, want: true},
		{name: "invalid descriptor", events: unix.POLLNVAL, want: true},
		{name: "failed poll", err: unix.EBADF, want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := pollReportsDisconnection(tc.events, tc.err); got != tc.want {
				t.Fatalf("pollReportsDisconnection(%#x, %v) = %t, want %t", tc.events, tc.err, got, tc.want)
			}
		})
	}
}

func TestDockerInfoAdvertisesRestartCapability(t *testing.T) {
	response := httptest.NewRecorder()
	(&dockerEngine{}).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1.47/info", nil))
	var info struct{ MicropodCapabilities []string }
	if err := json.Unmarshal(response.Body.Bytes(), &info); err != nil || response.Code != http.StatusOK {
		t.Fatalf("get info returned %d with %v", response.Code, err)
	}
	if !slices.Contains(info.MicropodCapabilities, "restart") {
		t.Fatalf("worker capabilities = %v, want restart", info.MicropodCapabilities)
	}
}

func TestDockerInfoAttestsTheEffectiveWorkspace(t *testing.T) {
	const workspace = `/private/tmp/build "two words" µ`
	const label = "io.micropod.workspace-sha256=abb068e4cbe6891a3d3eae567b8dc117ff8188acc867e3cb7636b9b5ebbf383a"
	for _, path := range []string{"", workspace} {
		response := httptest.NewRecorder()
		(&dockerEngine{workspace: path}).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1.47/info", nil))
		var info struct{ Labels []string }
		if err := json.Unmarshal(response.Body.Bytes(), &info); err != nil || response.Code != http.StatusOK {
			t.Fatalf("get info returned %d with %v", response.Code, err)
		}
		if slices.Contains(info.Labels, label) != (path != "") || strings.Contains(response.Body.String(), "two words") {
			t.Fatalf("unexpected workspace evidence in docker info: %v", info.Labels)
		}
	}
}

func TestDockerContainerListNamePatternsMatchStockDocker(t *testing.T) {
	owned := dockerConfig{Labels: map[string]string{"fixture": "owned"}}
	engine := &dockerEngine{containers: map[string]*dockerContainer{
		"first":   {dockerRecord: dockerRecord{ID: "first", Name: "sample", Phase: "running", Config: owned}},
		"second":  {dockerRecord: dockerRecord{ID: "second", Name: "sample-listener", Phase: "created", Config: owned}},
		"third":   {dockerRecord: dockerRecord{ID: "third", Name: "sample-database", Phase: "created", Config: owned}},
		"foreign": {dockerRecord: dockerRecord{ID: "foreign", Name: "sample-unused", Phase: "created"}},
	}}
	for _, tc := range []struct {
		name, filters string
		want          []string
	}{
		{"literal", `{"name":["sample"],"label":["fixture=owned"]}`, []string{"first", "second", "third"}},
		{"bare anchor", `{"name":{"^sample$":true},"label":{"fixture=owned":true}}`, []string{"first"}},
		{"absolute anchor", `{"name":["^/sample$"]}`, []string{"first"}},
		{"or group", `{"name":["^sample-(listener|database)$"]}`, []string{"second", "third"}},
		{"invalid", `{"name":["["]}`, nil},
		{"skip invalid", `{"name":["[","^sample$"]}`, []string{"first"}},
		{"legacy membership", `{"name":{"^sample$":false}}`, []string{"first"}},
		{"empty patterns", `{"name":[],"label":["fixture=owned"]}`, []string{"first", "second", "third"}},
		{"composed", `{"name":["^sample-"],"label":["fixture=owned"],"status":["created"],"id":["sec"]}`, []string{"second"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			query := url.Values{"all": {"1"}, "filters": {tc.filters}}
			engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/containers/json?"+query.Encode(), nil))
			var rows []dockerContainerListRow
			if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &rows) != nil {
				t.Fatalf("container list responded %d %s", w.Code, w.Body)
			}
			got := make([]string, 0, len(rows))
			for _, row := range rows {
				got = append(got, row.ID)
			}
			slices.Sort(got)
			if !slices.Equal(got, tc.want) {
				t.Fatalf("selected %v, want %v", got, tc.want)
			}
		})
	}
}

func TestDockerContainerListAndInspectReportEffectivePorts(t *testing.T) {
	config, err := parseDockerConfig([]byte(`{
		"Image":"fixture",
		"ExposedPorts":{"8080/tcp":{},"5353/udp":{}},
		"HostConfig":{"PortBindings":{"8080/tcp":[
			{"HostIp":"127.0.0.1","HostPort":""},{"HostIp":"127.0.0.1","HostPort":"9090"}],
			"8081/tcp":[{"HostIp":"127.0.0.1","HostPort":""}]}}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: "fixture", Phase: "created", Config: config}}
	engine := &dockerEngine{containers: map[string]*dockerContainer{c.ID: c}}
	get := func(path string, out any) {
		t.Helper()
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusOK {
			t.Fatalf("%s returned %d: %s", path, response.Code, response.Body)
		}
		if err := json.Unmarshal(response.Body.Bytes(), out); err != nil {
			t.Fatal(err)
		}
	}
	check := func(wantList, wantInspect string) {
		t.Helper()
		var rows []struct {
			ID    string `json:"Id"`
			Ports json.RawMessage
		}
		get("/v1.47/containers/json?all=1", &rows)
		if len(rows) != 1 || rows[0].ID != c.ID || string(rows[0].Ports) != wantList {
			t.Fatalf("container list = %+v, want ports %s", rows, wantList)
		}
		var inspect struct {
			NetworkSettings struct{ Ports json.RawMessage }
			Config          struct{ ExposedPorts map[string]struct{} }
		}
		get("/v1.47/containers/fixture/json", &inspect)
		if got := string(inspect.NetworkSettings.Ports); got != wantInspect {
			t.Fatalf("inspect ports = %s, want %s", got, wantInspect)
		}
		if !maps.Equal(inspect.Config.ExposedPorts, config.ExposedPorts) {
			t.Fatalf("configured exposures = %v, want %v", inspect.Config.ExposedPorts, config.ExposedPorts)
		}
	}
	check(`[]`, `{}`)
	c.Phase = "running"
	c.Ports = portMap{
		"8080/tcp": {{HostIP: "127.0.0.1", HostPort: "49152"}, {HostIP: "127.0.0.1", HostPort: "9090"}},
		"8081/tcp": {{HostIP: "127.0.0.1", HostPort: "49153"}},
	}
	check(`[{"PrivatePort":5353,"Type":"udp"},`+
		`{"IP":"127.0.0.1","PrivatePort":8080,"PublicPort":9090,"Type":"tcp"},`+
		`{"IP":"127.0.0.1","PrivatePort":8080,"PublicPort":49152,"Type":"tcp"},`+
		`{"IP":"127.0.0.1","PrivatePort":8081,"PublicPort":49153,"Type":"tcp"}]`,
		`{"5353/udp":null,"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"49152"},{"HostIp":"127.0.0.1","HostPort":"9090"}],`+
			`"8081/tcp":[{"HostIp":"127.0.0.1","HostPort":"49153"}]}`)
	c.Phase, c.Ports = "exited", nil
	check(`[]`, `{}`)
	c.Config.HostConfig.NetworkMode = "none"
	for _, phase := range []string{"created", "running", "exited"} {
		c.Phase = phase
		check(`[]`, `{}`)
	}
}

func TestPublishAllPortsUsesImageDefaults(t *testing.T) {
	config, err := parseDockerConfig([]byte(`{
		"Image":"fixture",
		"ExposedPorts":{"9000/tcp":{}},
		"HostConfig":{"PublishAllPorts":true,"PortBindings":{"08080/tcp":[
			{"HostIp":"127.0.0.1","HostPort":"9090"}]}}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	config.ExposedPorts = mergeImageExposedPorts(config.ExposedPorts,
		`{"imageSpec":{"config":{"ExposedPorts":{"8080/tcp":{},"8081/tcp":{}}}}}`)
	want := portMap{
		"8080/tcp": {{HostIP: "127.0.0.1", HostPort: "9090"}},
		"8081/tcp": {{}},
		"9000/tcp": {{}},
	}
	got, err := config.requestedPorts()
	if err != nil || !maps.EqualFunc(got, want, slices.Equal[[]portBinding]) {
		t.Fatalf("requested ports = %v, %v, want %v", got, err, want)
	}
	config.ExposedPorts["5353/udp"] = struct{}{}
	if ports, err := config.requestedPorts(); err == nil || ports != nil {
		t.Fatalf("unsupported UDP publication returned %v, %v", ports, err)
	}
	config.HostConfig.NetworkMode = "none"
	if ports, err := config.requestedPorts(); err == nil || ports != nil {
		t.Fatalf("explicit offline publication returned %v, %v", ports, err)
	}
	config.HostConfig.PortBindings = nil
	if ports, err := config.requestedPorts(); err != nil || len(ports) != 0 {
		t.Fatalf("implicit offline publication returned %v, %v", ports, err)
	}
}
