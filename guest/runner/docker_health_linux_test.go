package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	content "github.com/containerd/containerd/api/services/content/v1"
	images "github.com/containerd/containerd/api/services/images/v1"
	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestDockerHealthcheckConfig(t *testing.T) {
	for _, input := range []string{
		`{}`, `{"Healthcheck":null}`, `{"Healthcheck":{"Test":[]}}`,
		`{"Healthcheck":{"Test":["NONE"]}}`,
		`{"Healthcheck":{"Test":["CMD","test","-e","/ready"],"StartInterval":1000000}}`,
		`{"Healthcheck":{"Test":["CMD-SHELL","echo ready"],"Retries":1},"Shell":["/bin/bash","-ec"]}`,
	} {
		t.Run(input, func(t *testing.T) {
			body := `{"Image":"alpine:3.23"}`
			if input != "{}" {
				body = body[:len(body)-1] + "," + input[1:]
			}
			if _, err := parseDockerConfig([]byte(body)); err != nil {
				t.Fatal(err)
			}
		})
	}
	for _, input := range []string{
		`"fish"`, `{"Test":["BOGUS","foo"]}`, `{"Test":["CMD"]}`, `{"Test":["CMD-SHELL"]}`,
		`{"Test":["NONE","echo hi"]}`, `{"Test":["CMD",""]}`, `{"Test":["CMD","nul\u0000"]}`,
		`{"Interval":1}`, `{"Timeout":-1}`, `{"StartPeriod":22}`, `{"StartInterval":10}`,
		`{"Retries":-1}`, `{"Unknown":"meaningful"}`,
	} {
		t.Run(input, func(t *testing.T) {
			if _, err := parseDockerConfig([]byte(`{"Image":"alpine:3.23","Healthcheck":` + input + "}")); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}

	inherited := &dockerHealthConfig{
		Test: []string{"CMD-SHELL", "test -e /ready", "arg0"}, Interval: time.Second, Timeout: 2 * time.Second,
		StartPeriod: 3 * time.Second, StartInterval: 50 * time.Millisecond, Retries: 5,
	}
	requested := &dockerHealthConfig{Interval: 4 * time.Second}
	merged := mergeDockerHealth(requested, inherited)
	if !slices.Equal(merged.Test, inherited.Test) || merged.Interval != requested.Interval ||
		merged.Timeout != inherited.Timeout || merged.StartPeriod != inherited.StartPeriod ||
		merged.StartInterval != inherited.StartInterval || merged.Retries != inherited.Retries ||
		len(requested.Test) != 0 || inherited.Interval != time.Second {
		t.Fatalf("unexpected inherited config %+v", merged)
	}
	if want := []string{"/bin/sh", "-c", "test -e /ready", "arg0"}; !slices.Equal(merged.command(nil), want) {
		t.Fatalf("default shell = %q", merged.command(nil))
	}
	if want := []string{"/bin/ash", "-ec", "test -e /ready", "arg0"}; !slices.Equal(merged.command(want[:2]), want) {
		t.Fatalf("configured shell = %q", merged.command(want[:2]))
	}
	disabled := mergeDockerHealth(&dockerHealthConfig{Test: []string{"NONE"}}, inherited)
	if disabled.command(nil) != nil || disabled.Timeout != inherited.Timeout || disabled.Test[0] != "NONE" {
		t.Fatalf("disable changed the inherited metadata unexpectedly: %+v", disabled)
	}
}

type healthContentFixture struct {
	content.ContentClient
	read func(context.Context, *content.ReadContentRequest) (content.Content_ReadClient, error)
}

func (f healthContentFixture) Read(ctx context.Context, request *content.ReadContentRequest, _ ...grpc.CallOption) (content.Content_ReadClient, error) {
	return f.read(ctx, request)
}

type healthContentStream struct {
	content.Content_ReadClient
	data   []byte
	offset int
}

func (s *healthContentStream) Recv() (*content.ReadContentResponse, error) {
	if s.offset == len(s.data) {
		return nil, io.EOF
	}
	end := min(s.offset+(1<<20), len(s.data))
	chunk := &content.ReadContentResponse{Offset: int64(s.offset), Data: s.data[s.offset:end]}
	s.offset = end
	return chunk, nil
}

func healthConfigDigest(data []byte) string {
	return fmt.Sprintf("sha256:%x", sha256.Sum256(data))
}

func TestDockerHealthImageConfigUsesVerifiedSelectedConfig(t *testing.T) {
	scratch := t.TempDir()
	large := []byte(`{"config":{"OnBuild":["`)
	large = append(large, bytes.Repeat([]byte("x"), verifiedImageBlobLimit+10)...)
	large = append(large, []byte(`"],"Healthcheck":{"Test":["CMD","test","-e","/ready"]},"Shell":["/bin/sh","-ec"]}}`)...)
	for _, test := range []struct {
		name string
		data []byte
		want bool
		bad  bool
	}{
		{"minimal OCI", []byte(`{"rootfs":{"type":"layers","diff_ids":[]}}`), false, false},
		{"malformed", []byte(`{"config":{"Healthcheck":123}}`), false, true},
		{"null image", []byte("null"), false, true},
		{"trailing", []byte("{} {}"), false, true},
		{"large unrelated field", large, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			stream := &healthContentStream{data: test.data}
			image, err := decodeImageHealth(healthConfigDigest(test.data), stream.Recv, scratch)
			if (err != nil) != test.bad || (image.Healthcheck != nil) != test.want {
				t.Fatalf("image %+v, error %v", image, err)
			}
			if test.want && (!slices.Equal(image.Healthcheck.Test, []string{"CMD", "test", "-e", "/ready"}) ||
				!slices.Equal(image.Shell, []string{"/bin/sh", "-ec"}) || !image.cacheable()) {
				t.Fatalf("incorrect extraction or cache admission: %+v", image)
			}
			if files, err := os.ReadDir(scratch); err != nil || len(files) != 0 {
				t.Fatalf("config scratch leaked: %v, %v", files, err)
			}
		})
	}
	stream := &healthContentStream{data: []byte("{}")}
	if _, err := decodeImageHealth(healthConfigDigest([]byte("{ }")), stream.Recv, scratch); err == nil {
		t.Fatal("digest mismatch accepted")
	}
	if _, err := decodeImageHealth(healthConfigDigest([]byte("{}")), func() (*content.ReadContentResponse, error) {
		return &content.ReadContentResponse{Offset: 1, Data: []byte("{}")}, nil
	}, scratch); err == nil {
		t.Fatal("noncontiguous stream accepted")
	}
}

type dockerHealthTestImageStore struct{ imageMetadataClient }

func (dockerHealthTestImageStore) Get(_ context.Context, _ *images.GetImageRequest, _ ...grpc.CallOption) (*images.GetImageResponse, error) {
	return &images.GetImageResponse{}, nil
}

type dockerHealthTestImages struct {
	cri.ImageServiceClient
	id string
}

func (f dockerHealthTestImages) ImageStatus(_ context.Context, _ *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	return &cri.ImageStatusResponse{Image: &cri.Image{Id: f.id}}, nil
}

func TestDockerHealthImageReadErrorsFailCreateAndCanRetry(t *testing.T) {
	data := []byte("{}")
	malformed := []byte("{")
	malformedID := healthConfigDigest(malformed)
	id := healthConfigDigest(data)
	attempts := 0
	engine := &dockerEngine{node: node{
		images: dockerHealthTestImages{id: id}, imageStore: dockerHealthTestImageStore{},
		content: healthContentFixture{read: func(ctx context.Context, req *content.ReadContentRequest) (content.Content_ReadClient, error) {
			md, _ := metadata.FromOutgoingContext(ctx)
			if (req.GetDigest() != id && req.GetDigest() != malformedID) ||
				!slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) {
				t.Errorf("unexpected config content request %+v in %v", req, md)
			}
			attempts++
			switch attempts {
			case 1:
				return nil, status.Error(codes.NotFound, "missing")
			case 2:
				return &healthContentStream{data: malformed}, nil
			default:
				return &healthContentStream{data: data}, nil
			}
		}},
	}}
	for _, imageID := range []string{id, malformedID} {
		engine.node.images = dockerHealthTestImages{id: imageID}
		if _, err := engine.create(context.Background(), dockerConfig{Image: "alpine:3.23"}, "fixture"); err == nil {
			t.Fatal("create accepted unverified health metadata")
		} else if code := apiErrorCodeForHealthTest(err); code != 409 {
			t.Fatalf("create error %v has status %d", err, code)
		}
	}
	for range 2 {
		cfg := dockerConfig{}
		if err := engine.configureDockerHealth(context.Background(), &cfg, id); err != nil || cfg.Healthcheck != nil {
			t.Fatalf("cache recovery returned %+v, %v", cfg, err)
		}
	}
	if attempts != 3 {
		t.Fatalf("content reads %d, want two failed reads and one cached negative", attempts)
	}
}

func apiErrorCodeForHealthTest(err error) int {
	var target apiError
	if errors.As(err, &target) {
		return target.code
	}
	return 0
}

func TestDockerHealthImageCacheSharesLookupsAndEvictsOneEntry(t *testing.T) {
	first := []byte(`{"config":{},"v":0}`)
	firstID := healthConfigDigest(first)
	var firstReads atomic.Int32
	var current []byte
	engine := &dockerEngine{node: node{content: healthContentFixture{read: func(ctx context.Context, req *content.ReadContentRequest) (content.Content_ReadClient, error) {
		if req.GetDigest() == firstID {
			firstReads.Add(1)
			// Calls arriving during the first read must share it.
			time.Sleep(5 * time.Millisecond)
			return &healthContentStream{data: first}, ctx.Err()
		}
		return &healthContentStream{data: current}, ctx.Err()
	}}}}
	ctx := context.Background()
	var jobs sync.WaitGroup
	for range 8 {
		jobs.Go(func() {
			if _, err := engine.imageHealth(ctx, firstID); err != nil {
				t.Error(err)
			}
		})
	}
	jobs.Wait()
	if firstReads.Load() != 1 {
		t.Fatalf("concurrent containers made %d content reads", firstReads.Load())
	}
	for number := 1; number <= dockerHealthImageEntries; number++ {
		current = fmt.Appendf(nil, `{"config":{},"v":%d}`, number)
		if _, err := engine.imageHealth(ctx, healthConfigDigest(current)); err != nil {
			t.Fatal(err)
		}
	}
	if len(engine.healthImages.byID) != dockerHealthImageEntries {
		t.Fatalf("cache cleared or exceeded bound: %d entries", len(engine.healthImages.byID))
	}
	if _, err := engine.imageHealth(ctx, firstID); err != nil || firstReads.Load() != 2 {
		t.Fatalf("oldest cache entry was not evicted correctly: %v", err)
	}
}

func TestDockerHealthGraceThresholdHistoryAndEvents(t *testing.T) {
	begin := time.Now()
	cfg := &dockerHealthConfig{StartPeriod: 20 * time.Second, Interval: time.Second, StartInterval: time.Millisecond, Retries: 2}
	monitor := &dockerHealthMonitor{target: "generation-a", started: begin}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: "fixture", Phase: "running", RuntimeID: monitor.target,
		Health: &dockerHealthState{Status: dockerHealthStarting}}, healthMonitor: monitor}
	engine := &dockerEngine{}
	if got := c.Health.interval(cfg, time.Second); got != time.Millisecond {
		t.Fatalf("start interval %s", got)
	}
	probe := func(seconds int, code int32) {
		t.Helper()
		stamp := begin.Add(time.Duration(seconds) * time.Second)
		if !engine.recordDockerHealth(context.Background(), c, monitor, cfg, dockerHealthResult{Start: stamp, End: stamp, ExitCode: code}) {
			t.Fatal("live probe discarded")
		}
	}
	probe(1, 1)
	probe(3, 2)
	if c.Health.Status != dockerHealthStarting || c.Health.FailingStreak != 0 || len(c.Health.Log) != 2 {
		t.Fatalf("grace failed %+v", c.Health)
	}
	probe(4, 0)
	if c.Health.Status != dockerHealthHealthy || c.Health.interval(cfg, 4*time.Second) != time.Second {
		t.Fatalf("success during start period did not reset interval: %+v", c.Health)
	}
	probe(5, 1)
	if c.Health.Status != dockerHealthHealthy {
		t.Fatalf("threshold fired early: %+v", c.Health)
	}
	probe(6, 1)
	probe(7, 1)
	if c.Health.Status != dockerHealthUnhealthy || c.Health.FailingStreak != 3 {
		t.Fatalf("expected unhealthy: %+v", c.Health)
	}
	probe(8, 0)
	log := c.Health.Log
	if len(log) != 5 || !log[0].Start.Equal(begin.Add(4*time.Second)) || c.Health.FailingStreak != 0 {
		t.Fatalf("incorrect evicted log or streak: %+v", c.Health)
	}
	snapshot := c.inspect()["State"].(map[string]any)["Health"].(dockerHealthState)
	probe(9, 0)
	if !snapshot.Log[0].Start.Equal(begin.Add(4 * time.Second)) {
		t.Fatal("API snapshot shared its result ring")
	}
	cursor, err := engine.events.subscribe(true, false)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.events.unsubscribe()
	var actions []string
	for {
		event, ok, _ := engine.events.read(&cursor)
		if !ok {
			break
		}
		actions = append(actions, event.Action)
	}
	if !slices.Equal(actions, []string{"health_status: healthy", "health_status: unhealthy", "health_status: healthy"}) {
		t.Fatalf("health events = %v", actions)
	}
	c.RuntimeID = "generation-b"
	c.healthMonitor = &dockerHealthMonitor{target: c.RuntimeID, started: begin}
	if engine.recordDockerHealth(context.Background(), c, monitor, cfg, dockerHealthResult{ExitCode: 1}) {
		t.Fatal("old generation published a result")
	}
}

type dockerHealthExecFixture struct {
	*nativeExecFixture
	reapCtxOK atomic.Bool
	waits     atomic.Int32
	waiting   chan struct{}
}

func (f *dockerHealthExecFixture) Wait(ctx context.Context, req *tasks.WaitRequest, opts ...grpc.CallOption) (*tasks.WaitResponse, error) {
	if f.waits.Add(1) == 1 {
		close(f.waiting)
	}
	return f.nativeExecFixture.Wait(ctx, req, opts...)
}

func (f *dockerHealthExecFixture) Kill(ctx context.Context, req *tasks.KillRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	_, deadline := ctx.Deadline()
	f.reapCtxOK.Store(deadline && ctx.Err() == nil && req.GetExecID() == f.request.GetExecID() &&
		req.GetContainerID() == f.request.GetContainerID() && !req.GetAll())
	return f.nativeExecFixture.Kill(ctx, req, opts...)
}

func TestDockerHealthExecTimeoutKillsAndReapsOnlyProbe(t *testing.T) {
	engine, exec := testNativeExecEngine(t)
	f := &dockerHealthExecFixture{nativeExecFixture: exec, waiting: make(chan struct{})}
	exec.start = func(*tasks.ExecProcessRequest) error {
		<-f.waiting
		return nil
	}
	engine.node.execTasks = f
	result, err := engine.runDockerHealthProbe(context.Background(), "cri-container", []string{"sleep", "20"}, 20*time.Millisecond)
	if err != nil || result.ExitCode != -1 || !strings.Contains(result.Output, "timeout (20ms)") || !result.End.After(result.Start) {
		t.Fatalf("timeout result %+v: %v", result, err)
	}
	if !f.reapCtxOK.Load() || f.waits.Load() != 2 {
		t.Fatalf("probe was not reaped with a fresh bounded context, waits=%d", f.waits.Load())
	}
	select {
	case sig := <-exec.killed:
		if sig != uint32(unix.SIGKILL) {
			t.Fatalf("signal %d", sig)
		}
	default:
		t.Fatal("probe received no kill")
	}
	select {
	case <-exec.deleted:
	default:
		t.Fatal("probe task was not deleted")
	}
	if entries, err := os.ReadDir(engine.execPipeDir); err != nil || len(entries) != 0 {
		t.Fatalf("probe I/O leaked: %v, %v", entries, err)
	}
}

func TestDockerHealthExecKeepsIdentityAndBoundsOutput(t *testing.T) {
	engine, f := testNativeExecEngine(t)
	writeErr := make(chan error, 1)
	f.start = func(req *tasks.ExecProcessRequest) error {
		var spec struct {
			User map[string]int
			Cwd  string
			Env  []string
			Args []string
		}
		if err := json.Unmarshal(req.GetSpec().GetValue(), &spec); err != nil {
			return err
		}
		if req.GetTerminal() || req.GetStdin() != "" || req.GetStdout() == "" || req.GetStderr() == "" ||
			spec.User["uid"] != 1000 || spec.Cwd != "/fixture" || !slices.Equal(spec.Env, []string{"PERSIST=1"}) ||
			!slices.Equal(spec.Args, []string{"test", "-e", "/ready"}) {
			t.Errorf("probe did not inherit exact OCI identity: request %+v spec %+v", req, spec)
		}
		writer, err := f.openPipe(req.GetStderr(), os.O_WRONLY)
		if err != nil {
			return err
		}
		go func() {
			_, err := io.WriteString(writer, strings.Repeat("x", dockerHealthOutputLimit+200))
			writeErr <- errors.Join(err, writer.Close())
			f.exit(1)
		}()
		return nil
	}
	result, err := engine.runDockerHealthProbe(context.Background(), "cri-container", []string{"test", "-e", "/ready"}, time.Second)
	if err != nil || result.ExitCode != 1 || result.Output != strings.Repeat("x", dockerHealthOutputLimit)+"..." {
		t.Fatalf("exit=%d output length=%d cleanup=%v", result.ExitCode, len(result.Output), err)
	}
	if err := <-writeErr; err != nil {
		t.Fatal(err)
	}
	if len(engine.execs) != 0 {
		t.Fatal("probe left public exec entries")
	}
}

func TestDockerHealthStopJoinsAndRestartKeepsRecentResults(t *testing.T) {
	engine, f := testNativeExecEngine(t)
	began := make(chan struct{})
	f.start = func(_ *tasks.ExecProcessRequest) error {
		close(began)
		return nil
	}
	original := dockerHealthResult{Start: time.Now().Add(-time.Second), ExitCode: 1, Output: "older result"}
	c := &dockerContainer{dockerRecord: dockerRecord{
		ID: "fixture", Phase: "running", RuntimeID: "cri-container",
		Config: dockerConfig{Healthcheck: &dockerHealthConfig{Test: []string{"CMD", "sleep", "20"},
			Interval: time.Millisecond, Timeout: time.Hour}},
		Health: &dockerHealthState{Status: dockerHealthUnhealthy, FailingStreak: 3, Log: []dockerHealthResult{original}},
	}}

	engine.mu.Lock()
	engine.startDockerHealth(context.Background(), c)
	old := c.healthMonitor
	engine.mu.Unlock()
	select {
	case <-began:
	case <-time.After(time.Second):
		t.Fatal("health check did not start")
	}
	engine.mu.Lock()
	c.Health.Status = dockerHealthHealthy
	c.Health.FailingStreak = 2
	engine.mu.Unlock()
	engine.stopDockerHealth(c)
	if c.Health.Status != dockerHealthUnhealthy || c.Health.FailingStreak != 2 ||
		len(c.Health.Log) != 1 || c.Health.Log[0] != original || engine.events.next != 0 {
		t.Fatalf("stop changed the recorded probe history or published a probe event: %+v", c.Health)
	}
	select {
	case <-old.done:
	default:
		t.Fatal("retirement did not join the probe")
	}
	select {
	case <-f.deleted:
	default:
		t.Fatal("retirement did not reap its probe")
	}
	engine.mu.Lock()
	c.RuntimeID = "replacement"
	c.Config.Healthcheck.Interval = time.Hour
	c.Health.Status, c.Health.FailingStreak = dockerHealthUnhealthy, 4
	engine.startDockerHealth(context.Background(), c)
	replacement := c.healthMonitor
	stale := engine.recordDockerHealth(context.Background(), c, old, c.Config.Healthcheck, dockerHealthResult{ExitCode: 0})
	snapshot := c.Health.snapshot()
	engine.mu.Unlock()
	defer engine.stopDockerHealth(c)
	if replacement == old || replacement.target != "replacement" || stale || snapshot.Status != dockerHealthStarting ||
		snapshot.FailingStreak != 0 || len(snapshot.Log) != 1 || snapshot.Log[0] != original {
		t.Fatalf("replacement inherited stale work: %+v", snapshot)
	}
}

func TestDockerHealthImageCacheSurvivesCanceledLeader(t *testing.T) {
	data := []byte("{}")
	id := healthConfigDigest(data)
	var reads atomic.Int32
	began := make(chan struct{})
	engine := &dockerEngine{node: node{content: healthContentFixture{read: func(ctx context.Context, _ *content.ReadContentRequest) (content.Content_ReadClient, error) {
		if reads.Add(1) == 1 {
			close(began)
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return &healthContentStream{data: data}, nil
	}}}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	lead := make(chan error, 1)
	go func() {
		_, err := engine.imageHealth(ctx, id)
		lead <- err
	}()
	select {
	case <-began:
	case <-time.After(time.Second):
		t.Fatal("first config lookup did not start")
	}
	follower := make(chan error, 1)
	go func() {
		_, err := engine.imageHealth(context.Background(), id)
		follower <- err
	}()
	cancel()
	if err := <-lead; !errors.Is(err, context.Canceled) {
		t.Fatalf("lead read = %v", err)
	}
	if err := <-follower; err != nil || reads.Load() != 2 {
		t.Fatalf("follower read = %v, calls=%d", err, reads.Load())
	}
}

func TestDockerHealthImageInspectKeepsDeclaredShellWithoutInheritingIt(t *testing.T) {
	const ref = "micropod-qa/probe:fixture"
	data := []byte(`{"config":{"Healthcheck":{"Test":["CMD-SHELL","exit 0"],"Retries":2},"Shell":["/bin/bash","-lc"]}}`)
	id := healthConfigDigest(data)
	reads := 0
	engine := &dockerEngine{node: node{
		images: inspectImageStatus{t: t, reference: ref, response: &cri.ImageStatusResponse{
			Image: &cri.Image{Id: id}, Info: map[string]string{"info": `{"imageSpec":{"config":{"Cmd":["myapp"]}}}`},
		}},
		imageStore: dockerHealthTestImageStore{},
		containers: execSpecFixture{},
		execTasks:  &nativeExecFixture{},
		content: healthContentFixture{read: func(_ context.Context, _ *content.ReadContentRequest) (content.Content_ReadClient, error) {
			reads++
			return &healthContentStream{data: data}, nil
		}},
	}}
	w := httptest.NewRecorder()
	engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/images/"+ref+"/json", nil))
	var inspected struct {
		Config struct {
			dockerImageHealth
			Cmd []string
		}
	}
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &inspected) != nil {
		t.Fatalf("inspect returned %d: %s", w.Code, w.Body)
	}
	if !slices.Equal(inspected.Config.Cmd, []string{"myapp"}) ||
		!slices.Equal(inspected.Config.Shell, []string{"/bin/bash", "-lc"}) ||
		inspected.Config.Healthcheck == nil || inspected.Config.Healthcheck.Retries != 2 {
		t.Fatalf("image fields lost or changed: %s", w.Body)
	}
	container := dockerConfig{}
	if err := engine.configureDockerHealth(context.Background(), &container, id); err != nil {
		t.Fatal(err)
	}
	if want := []string{"/bin/sh", "-c", "exit 0"}; !slices.Equal(container.Healthcheck.command(container.Shell), want) {
		t.Fatalf("container inherited image shell: %+v", container)
	}
	container = dockerConfig{Shell: []string{"/bin/sh", "-ec"}}
	if err := engine.configureDockerHealth(context.Background(), &container, id); err != nil ||
		!slices.Equal(container.Healthcheck.command(container.Shell), []string{"/bin/sh", "-ec", "exit 0"}) {
		t.Fatalf("explicit container shell changed: %+v, %v", container, err)
	}
	if reads != 1 {
		t.Fatalf("inspect and creates made %d image config reads", reads)
	}
}

func TestDockerHealthQuickExitHasEmptyUnhealthyHistory(t *testing.T) {
	engine := &dockerEngine{}
	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "running", RuntimeID: "quick-job",
		Config: dockerConfig{Healthcheck: &dockerHealthConfig{
			Test: []string{"CMD", "true"}, Interval: time.Hour,
		}},
	}}
	engine.mu.Lock()
	engine.startDockerHealth(context.Background(), c)
	initial := c.Health.snapshot()
	engine.mu.Unlock()
	if initial.Status != dockerHealthStarting {
		t.Fatalf("initial status: %+v", initial)
	}

	engine.stopDockerHealth(c)
	c.Phase, c.RuntimeID = "exited", ""
	data, err := json.Marshal(c.inspect()["State"])
	if err != nil {
		t.Fatal(err)
	}
	var wire struct {
		Status string
		Health dockerHealthState
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		t.Fatal(err)
	}
	if wire.Status != "exited" || wire.Health.Status != dockerHealthUnhealthy || wire.Health.FailingStreak != 0 ||
		wire.Health.Log == nil || len(wire.Health.Log) != 0 || engine.events.next != 0 {
		t.Fatalf("quick exit invented health activity: %s", data)
	}
}
