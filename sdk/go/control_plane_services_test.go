package micropod

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sort"
	"sync"
	"testing"

	"connectrpc.com/connect"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// controlPlane answers every CacheService, RigService and TelemetryService
// RPC with a message that carries what it was asked, and records each call.
type controlPlane struct {
	micropodv1connect.UnimplementedCacheServiceHandler
	micropodv1connect.UnimplementedRigServiceHandler
	micropodv1connect.UnimplementedTelemetryServiceHandler
	mu     sync.Mutex
	called []string
}

func (c *controlPlane) saw(procedure string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.called = append(c.called, procedure)
}

func (c *controlPlane) GetCacheStatus(_ context.Context, r *connect.Request[micropodv1.GetCacheStatusRequest]) (*connect.Response[micropodv1.CacheStatus], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.CacheStatus{PolicyDigest: "75abc5e1efc67ade", Units: []*micropodv1.CacheUnit{{Scope: "s", Unit: "gomod", Bytes: 1 << 40}}}), nil
}

func (c *controlPlane) ListCacheUnits(_ context.Context, r *connect.Request[micropodv1.ListCacheUnitsRequest]) (*connect.Response[micropodv1.ListCacheUnitsResponse], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.ListCacheUnitsResponse{Units: []*micropodv1.CacheUnit{{Scope: r.Msg.GetScope()}}}), nil
}

func (c *controlPlane) ExplainContainerCache(_ context.Context, r *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.ContainerCacheExplain], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.ContainerCacheExplain{ContainerName: r.Msg.GetId()}), nil
}

func (c *controlPlane) SampleCacheDedupe(_ context.Context, r *connect.Request[micropodv1.SampleCacheDedupeRequest]) (*connect.Response[micropodv1.CacheDedupeSample], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.CacheDedupeSample{BucketsSampled: int32(r.Msg.GetBuckets())}), nil
}

func (c *controlPlane) PruneCaches(_ context.Context, r *connect.Request[micropodv1.PruneCachesRequest]) (*connect.Response[micropodv1.PruneCachesResponse], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.PruneCachesResponse{DryRun: !r.Msg.GetApply()}), nil
}

func (c *controlPlane) GetCachePolicy(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.CachePolicy], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.CachePolicy{Mode: "auto"}), nil
}

func (c *controlPlane) SetCachePolicy(_ context.Context, r *connect.Request[micropodv1.SetCachePolicyRequest]) (*connect.Response[micropodv1.SetCachePolicyResponse], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.SetCachePolicyResponse{Policy: &micropodv1.CachePolicy{MaxAgeDays: proto32(int32(r.Msg.GetMaxAgeDays()))}}), nil
}

func (c *controlPlane) GetRigHealth(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.RigHealth], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.RigHealth{Hvf: &micropodv1.RigHVFHealth{Phase: "running"}}), nil
}

func (c *controlPlane) GetRigMode(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.RigMode], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.RigMode{Mode: "container"}), nil
}

func (c *controlPlane) SetRigMode(_ context.Context, r *connect.Request[micropodv1.SetRigModeRequest]) (*connect.Response[micropodv1.RigMode], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.RigMode{Mode: r.Msg.GetMode()}), nil
}

func (c *controlPlane) GetHVFUpdateStatus(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.HVFUpdateStatus], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.HVFUpdateStatus{AvailableVersions: []string{"0.15.0"}}), nil
}

func (c *controlPlane) ApplyHVFUpdate(_ context.Context, r *connect.Request[micropodv1.HVFUpdateRequest]) (*connect.Response[micropodv1.HVFUpdateResult], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.HVFUpdateResult{Action: "noop"}), nil
}

func (c *controlPlane) RollbackHVFUpdate(_ context.Context, r *connect.Request[micropodv1.HVFUpdateRequest]) (*connect.Response[micropodv1.HVFUpdateResult], error) {
	c.saw(r.Spec().Procedure)
	if !r.Msg.GetForce() {
		return nil, connect.NewError(connect.CodeFailedPrecondition, nil)
	}
	return connect.NewResponse(&micropodv1.HVFUpdateResult{Action: "rolled_back"}), nil
}

func (c *controlPlane) GetMachineStatus(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.HVFMachineStatus], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.HVFMachineStatus{Phase: "running"}), nil
}

func (c *controlPlane) ControlMachine(_ context.Context, r *connect.Request[micropodv1.ControlMachineRequest]) (*connect.Response[micropodv1.HVFMachineStatus], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.HVFMachineStatus{Phase: map[string]string{"stop": "stopped"}[r.Msg.GetAction()], StoppedOnRequest: r.Msg.GetAction() == "stop"}), nil
}

func (c *controlPlane) GetTelemetryHealth(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.TelemetryHealth], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.TelemetryHealth{Verdict: "healthy"}), nil
}

func (c *controlPlane) ListTelemetryIssues(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.TelemetryIssues], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.TelemetryIssues{Issues: []*micropodv1.TelemetryIssue{{Status: 500}}}), nil
}

func (c *controlPlane) GetTraces(_ context.Context, r *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.TelemetryTraces], error) {
	c.saw(r.Spec().Procedure)
	return connect.NewResponse(&micropodv1.TelemetryTraces{OtlpJson: []byte(`{"resourceSpans":[]}`)}), nil
}

func proto32(v int32) *int32 { return &v }

func declared(t *testing.T, files ...protoreflect.FileDescriptor) []string {
	t.Helper()
	var out []string
	for _, f := range files {
		for i := 0; i < f.Services().Len(); i++ {
			s := f.Services().Get(i)
			for j := 0; j < s.Methods().Len(); j++ {
				out = append(out, "/"+string(s.FullName())+"/"+string(s.Methods().Get(j).Name()))
			}
		}
	}
	sort.Strings(out)
	return out
}

// Every CacheService, RigService and TelemetryService RPC the protos declare
// is reachable through the SDK's Client, in binary protobuf and proto-JSON,
// and carries its request and reply intact (backlog B38).
func TestClientReachesEveryControlPlaneRPC(t *testing.T) {
	for _, codec := range []struct {
		name string
		opts []connect.ClientOption
	}{{"proto", nil}, {"json", []connect.ClientOption{connect.WithProtoJSON()}}} {
		t.Run(codec.name, func(t *testing.T) {
			impl := &controlPlane{}
			mux := http.NewServeMux()
			for _, mount := range []func() (string, http.Handler){
				func() (string, http.Handler) { return micropodv1connect.NewCacheServiceHandler(impl) },
				func() (string, http.Handler) { return micropodv1connect.NewRigServiceHandler(impl) },
				func() (string, http.Handler) { return micropodv1connect.NewTelemetryServiceHandler(impl) },
			} {
				path, handler := mount()
				mux.Handle(path, handler)
			}
			server := httptest.NewServer(mux)
			defer server.Close()
			c := NewClient(server.URL, WithConnectOptions(codec.opts...))
			ctx := context.Background()
			empty := func() *connect.Request[micropodv1.Empty] { return connect.NewRequest(&micropodv1.Empty{}) }
			must := func(err error) {
				t.Helper()
				if err != nil {
					t.Fatal(err)
				}
			}

			status, err := c.GetCacheStatus(ctx, connect.NewRequest(&micropodv1.GetCacheStatusRequest{}))
			must(err)
			if status.Msg.GetPolicyDigest() != "75abc5e1efc67ade" || status.Msg.GetUnits()[0].GetBytes() != 1<<40 {
				t.Fatalf("GetCacheStatus: %v", status.Msg)
			}
			units, err := c.ListCacheUnits(ctx, connect.NewRequest(&micropodv1.ListCacheUnitsRequest{Scope: "proj"}))
			must(err)
			if units.Msg.GetUnits()[0].GetScope() != "proj" {
				t.Fatalf("ListCacheUnits: %v", units.Msg)
			}
			explain, err := c.ExplainContainerCache(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: "web-1"}))
			must(err)
			if explain.Msg.GetContainerName() != "web-1" {
				t.Fatalf("ExplainContainerCache: %v", explain.Msg)
			}
			dedupe, err := c.SampleCacheDedupe(ctx, connect.NewRequest(&micropodv1.SampleCacheDedupeRequest{Buckets: 4}))
			must(err)
			if dedupe.Msg.GetBucketsSampled() != 4 {
				t.Fatalf("SampleCacheDedupe: %v", dedupe.Msg)
			}
			pruned, err := c.PruneCaches(ctx, connect.NewRequest(&micropodv1.PruneCachesRequest{}))
			must(err)
			if !pruned.Msg.GetDryRun() {
				t.Fatal("PruneCaches: an empty request must be a dry run")
			}
			_, err = c.GetCachePolicy(ctx, empty())
			must(err)
			days := uint32(41)
			saved, err := c.SetCachePolicy(ctx, connect.NewRequest(&micropodv1.SetCachePolicyRequest{MaxAgeDays: &days}))
			must(err)
			if saved.Msg.GetPolicy().GetMaxAgeDays() != 41 {
				t.Fatalf("SetCachePolicy: %v", saved.Msg)
			}

			_, err = c.GetRigHealth(ctx, empty())
			must(err)
			_, err = c.GetRigMode(ctx, empty())
			must(err)
			mode, err := c.SetRigMode(ctx, connect.NewRequest(&micropodv1.SetRigModeRequest{Mode: "sandbox"}))
			must(err)
			if mode.Msg.GetMode() != "sandbox" {
				t.Fatalf("SetRigMode: %v", mode.Msg)
			}
			_, err = c.GetHVFUpdateStatus(ctx, empty())
			must(err)
			_, err = c.ApplyHVFUpdate(ctx, connect.NewRequest(&micropodv1.HVFUpdateRequest{}))
			must(err)
			if _, err = c.RollbackHVFUpdate(ctx, connect.NewRequest(&micropodv1.HVFUpdateRequest{})); connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Fatalf("RollbackHVFUpdate without force: %v", err)
			}
			_, err = c.GetMachineStatus(ctx, empty())
			must(err)
			stopped, err := c.ControlMachine(ctx, connect.NewRequest(&micropodv1.ControlMachineRequest{Action: "stop"}))
			must(err)
			if !stopped.Msg.GetStoppedOnRequest() {
				t.Fatalf("ControlMachine: %v", stopped.Msg)
			}

			_, err = c.GetTelemetryHealth(ctx, empty())
			must(err)
			_, err = c.ListTelemetryIssues(ctx, empty())
			must(err)
			traces, err := c.GetTraces(ctx, empty())
			must(err)
			if string(traces.Msg.GetOtlpJson()) != `{"resourceSpans":[]}` {
				t.Fatalf("GetTraces: %v", traces.Msg)
			}

			impl.mu.Lock()
			called := map[string]bool{}
			for _, p := range impl.called {
				called[p] = true
			}
			impl.mu.Unlock()
			var exercised []string
			for p := range called {
				exercised = append(exercised, p)
			}
			sort.Strings(exercised)
			want := declared(t, micropodv1.File_micropod_v1_cache_proto, micropodv1.File_micropod_v1_rig_proto,
				micropodv1.File_micropod_v1_telemetry_proto)
			if len(exercised) != len(want) {
				t.Fatalf("exercised %d RPCs, the protos declare %d:\n got %v\nwant %v", len(exercised), len(want), exercised, want)
			}
			for i := range want {
				if exercised[i] != want[i] {
					t.Fatalf("exercised %v, declared %v", exercised, want)
				}
			}
		})
	}
}
