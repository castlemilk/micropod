package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	control "github.com/moby/buildkit/api/services/control"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

type recordingBuildkitSolver struct {
	control.ControlClient
	request *control.SolveRequest
	md      metadata.MD
}

func (s *recordingBuildkitSolver) Solve(ctx context.Context, req *control.SolveRequest, _ ...grpc.CallOption) (*control.SolveResponse, error) {
	s.request = req
	s.md, _ = metadata.FromOutgoingContext(ctx)
	return &control.SolveResponse{}, nil
}

func TestDockerBuildkitSolveForwardsTheRequest(t *testing.T) {
	bk := &recordingBuildkitSolver{}
	solver := dockerBuildSolver{backend: bk}
	req := &control.SolveRequest{
		ExporterDeprecated: "moby",
		Exporters: []*control.Exporter{
			{Type: "local", Attrs: map[string]string{"platform-split": "false"}},
			{Type: "moby", Attrs: map[string]string{"name": "example/image:tag", "unpack": "false"}},
		},
	}
	// A newer BuildKit peer can add fields outside this runner's bindings.
	unknown := []byte{0xa0, 0x06, 0x01}
	req.ProtoReflect().SetUnknown(unknown)
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(
		"buildkit-test", "a", "buildkit-test", "b", "content-type", "application/grpc", ":authority", "example"))
	if _, err := solver.Solve(ctx, req); err != nil {
		t.Fatal(err)
	}
	got := bk.request
	if got.ExporterDeprecated != "image" || got.ExporterAttrsDeprecated["unpack"] != "true" ||
		got.Exporters[0].Type != "local" || got.Exporters[0].Attrs["platform-split"] != "false" ||
		got.Exporters[1].Type != "image" || got.Exporters[1].Attrs["name"] != "docker.io/example/image:tag" ||
		got.Exporters[1].Attrs["unpack"] != "true" || !bytes.Equal(unknown, got.ProtoReflect().GetUnknown()) {
		t.Fatalf("wrong BuildKit request: %v", got)
	}
	if len(bk.md) != 1 || len(bk.md.Get("buildkit-test")) != 2 {
		t.Fatalf("wrong BuildKit metadata: %v", bk.md)
	}
}

func TestDockerBuildkitNormalizesPublishedNames(t *testing.T) {
	kind := "moby"
	attrs := map[string]string{"name": "tool,example.test:5000/repo:ci,docker.io/library/tool:latest,"}
	tags, err := dockerImageExporter(&kind, &attrs)
	if err != nil || len(tags) != 2 || attrs["name"] != "docker.io/library/tool:latest,example.test:5000/repo:ci" ||
		attrs["dangling-name-prefix"] != "moby-dangling" || attrs["danging-name-empty-only"] != "true" {
		t.Fatalf("build names: %v %v %v", tags, attrs, err)
	}
	kind, attrs = "moby", map[string]string{"name": "BAD IMAGE"}
	if _, err := dockerImageExporter(&kind, &attrs); err == nil {
		t.Fatal("invalid build tag accepted")
	}
}

func TestDockerBuildkitIIDFromPublishedManifest(t *testing.T) {
	f := imageIDDeletionFixture(t)
	target := f.manifest.target
	raw, err := json.Marshal(map[string]any{"mediaType": target.MediaType, "digest": target.Digest, "size": target.Size})
	if err != nil {
		t.Fatal(err)
	}
	response := map[string]string{
		"containerimage.digest": target.Digest, "containerimage.descriptor": base64.StdEncoding.EncodeToString(raw),
	}
	solver := dockerBuildSolver{node: f.node}
	if err := solver.finishLocalLoad(context.Background(), []string{}, response); err != nil {
		t.Fatal(err)
	}
	if response["containerimage.config.digest"] != f.id || response["containerimage.digest"] != target.Digest {
		t.Fatalf("build result did not retain both image identities: %v", response)
	}
	delete(response, "containerimage.config.digest")
	response["containerimage.digest"] = f.id
	if err := solver.finishLocalLoad(context.Background(), nil, response); err == nil || response["containerimage.config.digest"] != "" {
		t.Fatalf("mismatched manifest accepted: %v, %v", response, err)
	}
	target.MediaType = "application/vnd.oci.image.index.v1+json"
	raw, err = json.Marshal(map[string]any{"mediaType": target.MediaType, "digest": target.Digest, "size": target.Size})
	if err != nil {
		t.Fatal(err)
	}
	response["containerimage.digest"] = target.Digest
	response["containerimage.descriptor"] = base64.StdEncoding.EncodeToString(raw)
	if err := solver.finishLocalLoad(context.Background(), nil, response); err != nil || response["containerimage.config.digest"] != f.id {
		t.Fatalf("published index did not resolve to its runnable config: %v, %v", response, err)
	}
}

func TestDockerBuildkitAvailabilityAndUpgrade(t *testing.T) {
	for _, test := range []struct {
		path, socket, protocol string
		want                   int
	}{
		{"/v1.47/grpc", "", "h2c", 503},
		{"/v1.47/grpc", "/local/bk.sock", "tcp", 400},
		{"/session", "/local/bk.sock", "h2c", 400},
	} {
		engine := dockerEngine{buildkitSocket: test.socket}
		r := httptest.NewRequest("POST", test.path, nil)
		r.Header.Set("Upgrade", test.protocol)
		r.Header.Set("Connection", "keep-alive, Upgrade")
		w := httptest.NewRecorder()
		engine.ServeHTTP(w, r)
		if w.Code != test.want {
			t.Errorf("%s: got %d want %d", test.path, w.Code, test.want)
		}
	}
	for _, socket := range []string{"", "/local/bk.sock"} {
		engine := dockerEngine{buildkitSocket: socket}
		for _, method := range []string{http.MethodHead, http.MethodGet} {
			w := httptest.NewRecorder()
			engine.ServeHTTP(w, httptest.NewRequest(method, "/_ping", nil))
			if got := w.Header().Get("Builder-Version"); (got == "2") != (socket != "") {
				t.Errorf("socket %q, %s: builder %q", socket, method, got)
			}
		}
	}
}
