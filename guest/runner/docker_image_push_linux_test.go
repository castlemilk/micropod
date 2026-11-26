package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	leases "github.com/containerd/containerd/api/services/leases/v1"
	streaming "github.com/containerd/containerd/api/services/streaming/v1"
	transferapi "github.com/containerd/containerd/api/services/transfer/v1"
	"github.com/containerd/containerd/api/types"
	transfer "github.com/containerd/containerd/api/types/transfer"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/emptypb"
)

type pushTestImages struct {
	imageMetadataClient
	entries []*images.Image
}

func (s pushTestImages) Get(ctx context.Context, req *images.GetImageRequest, _ ...grpc.CallOption) (*images.GetImageResponse, error) {
	for _, image := range s.entries {
		if image.GetName() == req.GetName() {
			return &images.GetImageResponse{Image: image}, nil
		}
	}
	return nil, status.Error(codes.NotFound, "image tag was not found")
}

func (s pushTestImages) List(context.Context, *images.ListImagesRequest, ...grpc.CallOption) (*images.ListImagesResponse, error) {
	return &images.ListImagesResponse{Images: s.entries}, nil
}

type pushTestStream struct {
	streaming.Streaming_StreamServer
	closed   chan struct{}
	returned chan struct{}
	lease    string
}

type pushTestTransfer struct {
	streaming.UnimplementedStreamingServer
	transferapi.UnimplementedTransferServer
	leases.UnimplementedLeasesServer
	mu      sync.Mutex
	streams map[string]pushTestStream
	leases  map[string]string
	handle  func(context.Context, *transfer.ImageStore, *transfer.OCIRegistry, pushTestStream, pushTestStream) error
}

func (s *pushTestTransfer) Create(ctx context.Context, req *leases.CreateRequest) (*leases.CreateResponse, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	expiry, err := time.Parse(time.RFC3339, req.GetLabels()["containerd.io/gc.expire"])
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) || !strings.HasPrefix(req.GetID(), "mp-image-push-") ||
		err != nil || time.Until(expiry) <= 0 {
		return nil, status.Error(codes.InvalidArgument, "invalid transfer lease")
	}
	s.mu.Lock()
	s.leases[req.GetID()] = ""
	s.mu.Unlock()
	return &leases.CreateResponse{Lease: &leases.Lease{ID: req.GetID()}}, nil
}

func (s *pushTestTransfer) AddResource(ctx context.Context, req *leases.AddResourceRequest) (*emptypb.Empty, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	id, resource := req.GetID(), req.GetResource()
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) ||
		!slices.Equal(md.Get("containerd-lease"), []string{id}) || resource.GetType() != "content" || !fullDockerImageID(resource.GetID()) {
		return nil, status.Error(codes.InvalidArgument, "invalid leased transfer content")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if retained, ok := s.leases[id]; !ok || retained != "" {
		return nil, status.Error(codes.FailedPrecondition, "expected an unused transfer lease")
	}
	s.leases[id] = resource.GetID()
	return &emptypb.Empty{}, nil
}

func (s *pushTestTransfer) Delete(ctx context.Context, req *leases.DeleteRequest) (*emptypb.Empty, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) || len(md.Get("containerd-lease")) != 0 || req.GetSync() {
		return nil, status.Error(codes.InvalidArgument, "invalid transfer lease cleanup")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.leases[req.GetID()]; !ok {
		return nil, status.Error(codes.NotFound, "transfer lease is missing")
	}
	delete(s.leases, req.GetID())
	return &emptypb.Empty{}, nil
}

func (s *pushTestTransfer) Stream(stream streaming.Streaming_StreamServer) error {
	message, err := stream.Recv()
	if err != nil {
		return err
	}
	var init streaming.StreamInit
	if message.GetTypeUrl() != "containerd.services.streaming.v1.StreamInit" || unmarshalRegistryPushAny(message, &init) != nil {
		return status.Error(codes.InvalidArgument, "wrong stream handshake")
	}
	md, _ := metadata.FromIncomingContext(stream.Context())
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) || len(md.Get("containerd-lease")) != 1 {
		return status.Error(codes.InvalidArgument, "unscoped transfer stream")
	}
	entry := pushTestStream{Streaming_StreamServer: stream, closed: make(chan struct{}), returned: make(chan struct{}), lease: md.Get("containerd-lease")[0]}
	s.mu.Lock()
	if _, ok := s.leases[entry.lease]; !ok {
		s.mu.Unlock()
		return status.Error(codes.InvalidArgument, "unleased transfer stream")
	}
	s.streams[init.GetID()] = entry
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.streams, init.GetID())
		s.mu.Unlock()
		close(entry.returned)
	}()
	if err := stream.Send(&anypb.Any{TypeUrl: "google.protobuf.Empty"}); err != nil {
		return err
	}
	select {
	case <-entry.closed:
		return nil
	case <-stream.Context().Done():
		return stream.Context().Err()
	}
}

func (s *pushTestTransfer) Transfer(ctx context.Context, req *transferapi.TransferRequest) (*emptypb.Empty, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) {
		return nil, status.Error(codes.InvalidArgument, "wrong image namespace")
	}
	var src transfer.ImageStore
	var dst transfer.OCIRegistry
	if req.GetSource().GetTypeUrl() != "containerd.types.transfer.ImageStore" || unmarshalRegistryPushAny(req.GetSource(), &src) != nil ||
		req.GetDestination().GetTypeUrl() != "containerd.types.transfer.OCIRegistry" || unmarshalRegistryPushAny(req.GetDestination(), &dst) != nil {
		return nil, status.Error(codes.InvalidArgument, "wrong transfer source or destination")
	}
	s.mu.Lock()
	progress := s.streams[req.GetOptions().GetProgressStream()]
	auth := s.streams[dst.GetResolver().GetAuthStream()]
	s.mu.Unlock()
	if progress.closed == nil || !slices.Equal(md.Get("containerd-lease"), []string{progress.lease}) || auth.closed != nil && auth.lease != progress.lease {
		return nil, status.Error(codes.InvalidArgument, "transfer and streams do not share a lease")
	}
	defer close(progress.closed)
	return &emptypb.Empty{}, s.handle(ctx, &src, &dst, progress, auth)
}

func pushTestEngine(t *testing.T, h func(context.Context, *transfer.ImageStore, *transfer.OCIRegistry, pushTestStream, pushTestStream) error) (*dockerEngine, *pushTestTransfer) {
	t.Helper()
	listener := bufconn.Listen(64 << 10)
	server := grpc.NewServer()
	fixture := &pushTestTransfer{streams: make(map[string]pushTestStream), leases: make(map[string]string), handle: h}
	streaming.RegisterStreamingServer(server, fixture)
	transferapi.RegisterTransferServer(server, fixture)
	leases.RegisterLeasesServer(server, fixture)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		fixture.mu.Lock()
		defer fixture.mu.Unlock()
		if len(fixture.leases) != 0 {
			t.Errorf("%d image push leases remained after the request", len(fixture.leases))
		}
	})
	t.Cleanup(server.Stop)
	conn, err := grpc.NewClient("passthrough:///local-containerd", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return listener.DialContext(ctx) }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return &dockerEngine{node: node{imageStore: pushTestImages{entries: []*images.Image{
		{Name: "fixture.registry:8443/team/image:beta"},
		{Name: "fixture.registry:8443/team/image:alpha"},
		{Name: "fixture.registry:8443/team/image-other:alpha"},
	}}, imagePush: newDockerRegistryPusher(conn)}}, fixture
}

func TestDockerImagePushStreamsProgressAndScopesCredentials(t *testing.T) {
	const repository = "fixture.registry:8443/team/image"
	digest := "sha256:" + strings.Repeat("a", 64)
	engine, _ := pushTestEngine(t, func(_ context.Context, src *transfer.ImageStore, dst *transfer.OCIRegistry, progress, auth pushTestStream) error {
		ref := dst.GetReference()
		if !(ref == repository+":alpha" || ref == repository+":beta") || ref != src.GetName() ||
			dst.GetResolver().GetDefaultScheme() != "https" || len(dst.GetResolver().GetHeaders()) != 0 || auth.closed == nil {
			t.Error("the transfer did not select an exact local tag and a TLS registry auth stream")
			return status.Error(codes.InvalidArgument, "unexpected transfer")
		}
		for _, request := range []struct{ host, name string }{
			{"different.registry:8443", ref}, {"fixture.registry:8443", ref + "-wrong"}, {"fixture.registry:8443", ref},
		} {
			wire, err := registryPushAny(&transfer.AuthRequest{Host: request.host, Reference: request.name})
			if err != nil {
				return err
			}
			if err := auth.Send(wire); err != nil {
				return err
			}
			wire, err = auth.Recv()
			if err != nil {
				return err
			}
			var answer transfer.AuthResponse
			if err := unmarshalRegistryPushAny(wire, &answer); err != nil {
				return err
			}
			if request.host == "fixture.registry:8443" && request.name == ref {
				if answer.GetAuthType() != transfer.AuthType_CREDENTIALS || answer.GetUsername() != "test-user" || answer.GetSecret() != "synthetic" {
					t.Error("the matching registry did not receive the scoped credential")
				}
			} else if answer.GetAuthType() != transfer.AuthType_NONE || answer.GetUsername() != "" || answer.GetSecret() != "" {
				t.Error("credentials crossed the exact registry and reference boundary")
			}
		}
		close(auth.closed)
		<-auth.returned
		desc := &types.Descriptor{Digest: digest, Size: 29}
		child := &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64), Size: 7}
		for _, event := range []*transfer.Progress{
			{Event: "pushing content", Name: src.GetName(), Desc: desc},
			{Event: "waiting", Desc: desc, Total: 29},
			{Event: "uploading", Desc: desc, Progress: 7, Total: 29},
			{Event: "pushed content", Name: src.GetName(), Desc: desc},
			{Event: "pushed content", Name: src.GetName(), Desc: child},
		} {
			wire, err := registryPushAny(event)
			if err != nil {
				return err
			}
			if err := progress.Send(wire); err != nil {
				return err
			}
		}
		return nil
	})
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1.47/images/"+repository+"/push", nil)
	r.Header.Set("X-Registry-Auth", base64.RawURLEncoding.EncodeToString([]byte(`{"username":"test-user","password":"synthetic","serveraddress":"https://fixture.registry:8443/"}`)))
	if err := engine.images(w, r, repository+"/push"); err != nil || w.Code != http.StatusOK || !w.Flushed {
		t.Fatalf("push returned status %d, flushed %v, error %v", w.Code, w.Flushed, err)
	}
	decoder := json.NewDecoder(w.Body)
	var pushed []string
	pushing := 0
	for {
		var event dockerPushMessage
		if err := decoder.Decode(&event); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		if event.Error != "" {
			t.Fatal("successful push returned a stream error")
		}
		if event.Status == "Pushing" && event.ID == strings.Repeat("a", 12) && event.ProgressDetail != nil && *event.ProgressDetail == (dockerPushProgress{7, 29}) {
			pushing++
		}
		if event.Aux != nil {
			if event.Aux.Digest != digest || event.Aux.Size != 29 {
				t.Fatalf("invalid manifest receipt %+v", event.Aux)
			}
			pushed = append(pushed, event.Aux.Tag)
		}
	}
	if !slices.Equal(pushed, []string{"alpha", "beta"}) || pushing != 2 {
		t.Fatalf("manifest receipts %v, progress updates %d", pushed, pushing)
	}
}

func TestDockerImagePushLeasesSelectedContentBeforeReleasingImageWrites(t *testing.T) {
	const ref = "fixture.registry:8443/team/image:alpha"
	desc := &types.Descriptor{Digest: "sha256:" + strings.Repeat("f", 64), Size: 29}
	selected, resume := make(chan struct{}), make(chan struct{})
	engine, fixture := pushTestEngine(t, func(ctx context.Context, src *transfer.ImageStore, _ *transfer.OCIRegistry, progress, _ pushTestStream) error {
		for _, event := range []string{"pushing content", "pushed content"} {
			wire, err := registryPushAny(&transfer.Progress{Event: event, Name: src.GetName(), Desc: desc})
			if err != nil {
				return err
			}
			if err := progress.Send(wire); err != nil {
				return err
			}
			if event == "pushing content" {
				close(selected)
				select {
				case <-resume:
				case <-ctx.Done():
					return ctx.Err()
				}
			}
		}
		return nil
	})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	w := httptest.NewRecorder()
	r := httptest.NewRequestWithContext(ctx, http.MethodPost, "/v1.47/images/"+ref+"/push", nil)
	finished := make(chan error, 1)
	go func() { finished <- engine.images(w, r, ref+"/push") }()
	select {
	case <-selected:
	case <-ctx.Done():
		t.Fatal("push source was not selected")
	}
	retained := make(chan string, 1)
	go func() {
		engine.imageMu.Lock()
		defer engine.imageMu.Unlock()
		fixture.mu.Lock()
		defer fixture.mu.Unlock()
		for _, digest := range fixture.leases {
			retained <- digest
			return
		}
		retained <- ""
	}()
	select {
	case digest := <-retained:
		if digest != desc.GetDigest() {
			t.Fatalf("image mutation resumed without leasing the selected digest, got %q", digest)
		}
	case <-ctx.Done():
		t.Fatal("image mutation remained blocked by an active transfer")
	}
	close(resume)
	select {
	case err := <-finished:
		if err != nil || !strings.Contains(w.Body.String(), `"aux":{"Tag":"alpha","Digest":"`+desc.GetDigest()+`"`) {
			t.Fatalf("push did not finish with the leased root, error %v, body %s", err, w.Body)
		}
	case <-ctx.Done():
		t.Fatal("push did not finish")
	}
}

func TestDockerImagePushRequiresMatchingSourceAndCompletion(t *testing.T) {
	const ref = "fixture.registry:8443/team/image:alpha"
	source := &transfer.Progress{Event: "pushing content", Name: ref, Desc: &types.Descriptor{Digest: "sha256:" + strings.Repeat("a", 64), Size: 29}}
	child := &transfer.Progress{Event: "pushed content", Name: ref, Desc: &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64), Size: 7}}
	for _, tc := range []struct {
		name   string
		events []*transfer.Progress
	}{
		{"no initial source", []*transfer.Progress{child}},
		{"no completion", []*transfer.Progress{source}},
		{"wrong completion", []*transfer.Progress{source, child}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine, _ := pushTestEngine(t, func(_ context.Context, _ *transfer.ImageStore, _ *transfer.OCIRegistry, progress, _ pushTestStream) error {
				for _, event := range tc.events {
					wire, err := registryPushAny(event)
					if err != nil {
						return err
					}
					if err := progress.Send(wire); err != nil {
						return err
					}
				}
				return nil
			})
			w := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodPost, "/v1.47/images/"+ref+"/push", nil)
			if err := engine.images(w, r, ref+"/push"); err != nil || !strings.Contains(w.Body.String(), `"error":"image push failed"`) || strings.Contains(w.Body.String(), `"aux":`) {
				t.Fatalf("push without confirmed completion returned %v, body %s", err, w.Body)
			}
			if !engine.imageMu.TryLock() {
				t.Fatal("push without confirmed completion blocked image writes")
			}
			engine.imageMu.Unlock()
		})
	}
}

func TestDockerImagePushRedactsStreamError(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status error
		want   string
	}{
		{"typed", status.Error(codes.PermissionDenied, "authorization response with synthetic secret"), "registry denied image push"},
		{"upstream unknown 401", status.Error(codes.Unknown, "unexpected status from HEAD request to https://fixture.registry:8443/path: 401 Unauthorized\nunauthorized: synthetic secret"), "registry denied image push"},
		{"unrelated unknown", status.Error(codes.Unknown, "upload error: synthetic secret: 401 Unauthorized"), "image push failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine, _ := pushTestEngine(t, func(_ context.Context, _ *transfer.ImageStore, _ *transfer.OCIRegistry, _, auth pushTestStream) error {
				if auth.closed != nil {
					t.Error("anonymous transfer opened an auth stream")
				}
				return tc.status
			})
			w := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodPost, "/v1.47/images/fixture.registry:8443/team/image/push?tag=alpha", nil)
			if err := engine.images(w, r, "fixture.registry:8443/team/image/push"); err != nil || w.Code != http.StatusOK ||
				strings.Contains(w.Body.String(), "synthetic secret") || !strings.Contains(w.Body.String(), `"errorDetail":{"message":"`+tc.want+`"}`) ||
				strings.Contains(w.Body.String(), `"aux":`) {
				t.Fatalf("unexpected error stream status %d, error %v", w.Code, err)
			}
		})
	}
}

func TestDockerImagePushCancelsTransfer(t *testing.T) {
	started := make(chan struct{})
	engine, _ := pushTestEngine(t, func(ctx context.Context, _ *transfer.ImageStore, _ *transfer.OCIRegistry, _, _ pushTestStream) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1.47/images/fixture.registry:8443/team/image/push?tag=alpha", nil).WithContext(ctx)
	r.Header.Set("X-Registry-Auth", base64.URLEncoding.EncodeToString([]byte(`{"username":"test-user","password":"synthetic"}`)))
	finished := make(chan error, 1)
	go func() { finished <- engine.images(w, r, "fixture.registry:8443/team/image/push") }()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("push transfer never started")
	}
	cancel()
	select {
	case err := <-finished:
		if err != nil || strings.Contains(w.Body.String(), `"aux":`) || strings.Contains(w.Body.String(), `"error":`) {
			t.Fatalf("canceled push returned terminal progress or error %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("push handler did not stop after cancellation")
	}
	if !engine.imageMu.TryLock() {
		t.Fatal("canceled push blocked image writes")
	}
	engine.imageMu.Unlock()
}

func TestDockerImagePushRejectsInvalidRequests(t *testing.T) {
	const name = "fixture.registry:8443/team/image"
	engine := &dockerEngine{node: node{imageStore: pushTestImages{}}}
	for _, tc := range []struct {
		name, ref, query, auth string
		code                   int
	}{
		{name: "invalid tag", ref: name, query: "tag=one/two", code: 400},
		{name: "conflicting tags", ref: name + ":one", query: "tag=two", code: 400},
		{name: "duplicate tag", ref: name, query: "tag=one&tag=two", code: 400},
		{name: "digest", ref: name + "@sha256:" + strings.Repeat("a", 64), code: 400},
		{name: "wrong registry", ref: name, auth: `{"username":"test-user","password":"synthetic","serveraddress":"other.registry:8443"}`, code: 400},
		{name: "wrong port", ref: name, auth: `{"serveraddress":"fixture.registry:443"}`, code: 400},
		{name: "invalid auth JSON", ref: name, auth: `{"username":`, code: 400},
		{name: "unsupported registry token", ref: name, auth: `{"registrytoken":"synthetic"}`, code: 501},
		{name: "unsupported platform selection", ref: name, query: "platform=linux%2Farm64", code: 501},
		{name: "missing tag", ref: name, query: "tag=missing", code: 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/v1.47/images/"+tc.ref+"/push?"+tc.query, nil)
			if tc.auth != "" {
				r.Header.Set("X-Registry-Auth", base64.URLEncoding.EncodeToString([]byte(tc.auth)))
			}
			w := httptest.NewRecorder()
			var failure apiError
			if err := engine.images(w, r, tc.ref+"/push"); !errors.As(err, &failure) || failure.code != tc.code || w.Flushed {
				t.Fatalf("push error %v, flushed %v, want HTTP %d before streaming", err, w.Flushed, tc.code)
			}
		})
	}
}

func TestDockerImagePushPreservesActualStoredTag(t *testing.T) {
	ref, err := imagePushReference("fixture", "current")
	if err != nil {
		t.Fatal(err)
	}
	const alias = "fixture:current"
	const canonical = "docker.io/library/fixture:current"
	first := &images.Image{Name: alias, Target: &types.Descriptor{Digest: "sha256:" + strings.Repeat("a", 64)}}
	second := &images.Image{Name: "index.docker.io/fixture:current", Target: &types.Descriptor{Digest: "sha256:" + strings.Repeat("b", 64)}}
	n := node{imageStore: pushTestImages{entries: []*images.Image{first}}}
	if tags, err := n.imagePushTargets(context.Background(), ref); err != nil || len(tags) != 1 || tags[0].source != alias || tags[0].ref.String() != canonical {
		t.Fatalf("imported tag lookup returned %v, %v", tags, err)
	}
	n.imageStore = pushTestImages{entries: []*images.Image{first, second}}
	var failure apiError
	if _, err := n.imagePushTargets(context.Background(), ref); !errors.As(err, &failure) || failure.code != http.StatusConflict {
		t.Fatalf("ambiguous import lookup returned %v, want conflict", err)
	}
	ref, err = imagePushReference("fixture", "")
	if err != nil {
		t.Fatal(err)
	}
	n.imageStore = pushTestImages{entries: []*images.Image{first, second, {Name: canonical, Target: first.Target}}}
	if tags, err := n.imagePushTargets(context.Background(), ref); err != nil || len(tags) != 1 || tags[0].source != canonical {
		t.Fatalf("canonical tag lookup returned %v, %v", tags, err)
	}
}
