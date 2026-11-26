package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/containerd/containerd/api/types"
	control "github.com/moby/buildkit/api/services/control"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"golang.org/x/net/http/httpguts"
	"golang.org/x/net/http2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	_ "google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// net/http may have read the first HTTP/2 frame along with the upgrade headers.
type buildkitClientConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c buildkitClientConn) Read(b []byte) (int, error) { return c.reader.Read(b) }

func (s *dockerEngine) dockerBuildkitUpgrade(w http.ResponseWriter, r *http.Request, path string) error {
	if s.buildkitSocket == "" {
		return fail(http.StatusServiceUnavailable, "BuildKit is unavailable")
	}
	if !strings.EqualFold(r.Header.Get("Upgrade"), "h2c") ||
		!httpguts.HeaderValuesContainsToken(r.Header.Values("Connection"), "upgrade") {
		return fail(http.StatusBadRequest, "BuildKit requires an h2c connection upgrade")
	}
	if path == "session" && r.Header.Get("X-Docker-Expose-Session-Uuid") == "" {
		return fail(http.StatusBadRequest, "missing BuildKit session ID")
	}
	cc, err := grpc.NewClient("unix://"+s.buildkitSocket, grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(buildkitMaxMessage), grpc.MaxCallSendMsgSize(buildkitMaxMessage)))
	if err != nil {
		return err
	}
	defer cc.Close()
	conn, rw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return err
	}
	defer conn.Close()
	// The HTTP server's request timeout must not cut off a long build.
	if err := conn.SetDeadline(time.Time{}); err != nil {
		return nil
	}
	if _, err := rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n"); err != nil || rw.Flush() != nil {
		return nil
	}
	stop := context.AfterFunc(r.Context(), func() { conn.Close() })
	defer stop()
	client := buildkitClientConn{conn, rw.Reader}
	bk := control.NewControlClient(cc)
	if path == "session" {
		serveDockerBuildSession(r, client, bk)
	} else {
		s.serveDockerBuildControl(r.Context(), client, bk)
	}
	return nil
}

// Docker hands its Buildx control client an HTTP/2 connection. Pass streaming
// RPCs, status trailers, and frontend gateway calls through to the local worker.
// Only Solve needs the embedded Docker exporter's name translated.
//
// There is one buildkitd for the machine, and its API takes no caller: any
// client can list every build (ListenBuildHistory), read a record's build
// args, exporter response and logs (the record and its blobs through the
// content service), stream an active build's output (Status), drive its
// frontend gateway (LLBBridge, by build ID) or delete and pin records. On a
// delegated socket (viewerOf(ctx) set) a build is its own job's: Solve
// records whose each build is (dockerBuildRefs) and takes no ref buildkitd
// already has (knownToBuildkit), Status and the frontend
// gateway reach only a build of the same socket's, the cache (DiskUsage,
// Prune), the workers, Info, a session and the health check stay the
// machine's, and anything else (the history, the content and trace
// services, reflection) is refused.
func (s *dockerEngine) serveDockerBuildControl(ctx context.Context, conn net.Conn, bk control.ControlClient) {
	transport := &http2.Transport{AllowHTTP: true, DialTLSContext: func(ctx context.Context, _, _ string, _ *tls.Config) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", s.buildkitSocket)
	}}
	defer transport.CloseIdleConnections()
	proxy := httputil.ReverseProxy{Transport: transport, FlushInterval: -1, Rewrite: func(r *httputil.ProxyRequest) {
		r.Out.URL.Scheme, r.Out.URL.Host, r.Out.Host = "http", "localhost", "localhost"
	}}
	viewer := viewerOf(ctx)
	solver := grpc.NewServer(grpc.MaxRecvMsgSize(buildkitMaxMessage), grpc.MaxSendMsgSize(buildkitMaxMessage))
	control.RegisterControlServer(solver, dockerBuildSolver{backend: bk, node: s.node, viewer: viewer, builds: &s.builds})
	defer solver.Stop()
	refuse := grpc.NewServer(grpc.UnknownServiceHandler(func(_ any, stream grpc.ServerStream) error {
		if method, _ := grpc.MethodFromServerStream(stream); strings.HasPrefix(method, buildkitGatewayService) {
			return status.Error(codes.NotFound, "no such build on this Docker socket")
		}
		return status.Error(codes.PermissionDenied, "this BuildKit call is unavailable on a container's Docker socket: the machine's builds are not its own")
	}))
	defer refuse.Stop()
	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		method := req.URL.Path
		switch {
		case method == control.Control_Solve_FullMethodName:
			solver.ServeHTTP(w, req)
		case viewer == "":
			proxy.ServeHTTP(w, req)
		case method == control.Control_Status_FullMethodName:
			solver.ServeHTTP(w, req)
		case strings.HasPrefix(method, buildkitGatewayService):
			// The gateway client may call before its Solve has arrived.
			if s.builds.owns(req.Context(), req.Header.Get(buildkitBuildIDHeader), viewer, buildkitRefWait) {
				proxy.ServeHTTP(w, req)
			} else {
				refuse.ServeHTTP(w, req)
			}
		case delegatedBuildkitCall(method):
			proxy.ServeHTTP(w, req)
		default:
			refuse.ServeHTTP(w, req)
		}
	})
	server := &http2.Server{IdleTimeout: time.Minute}
	server.ServeConn(conn, &http2.ServeConnOpts{Context: ctx, Handler: handler})
}

// buildkitGatewayService is the frontend gateway's service, whose calls name
// their build by buildkitBuildIDHeader (BuildKit's client/buildid).
const (
	buildkitGatewayService = "/moby.buildkit.v1.frontend.LLBBridge/"
	buildkitBuildIDHeader  = "buildkit-controlapi-buildid"
)

// buildkitRefWait is how long a delegated socket's Status or gateway call
// waits for the Solve of its build to arrive (a client starts both at once);
// a build that is not the socket's own is refused after it. A variable for
// tests.
var buildkitRefWait = 10 * time.Second

// buildkitRefGrace is how long whose a build is stays known once its Solve
// has returned, for a client's trailing Status of it.
const buildkitRefGrace = time.Minute

// What a delegated socket can make the engine keep is bounded: its build
// refs are at most buildkitMaxRef bytes (BuildKit's own are 25 characters),
// and it holds at most buildkitRefsPerSocket of them in dockerBuildRefs (its
// builds that run, or ended less than buildkitRefGrace ago).
const (
	buildkitMaxRef        = 64
	buildkitRefsPerSocket = 256
)

// delegatedBuildkitCall reports whether a delegated socket passes method
// through as it is: the machine's cache, workers and version, a session the
// client serves, and the health check.
func delegatedBuildkitCall(method string) bool {
	switch method {
	case control.Control_DiskUsage_FullMethodName, control.Control_Prune_FullMethodName, control.Control_Session_FullMethodName,
		control.Control_ListWorkers_FullMethodName, control.Control_Info_FullMethodName:
		return true
	}
	return strings.HasPrefix(method, "/grpc.health.v1.Health/")
}

// dockerBuildRefs records whose each build solved through the Docker socket
// proxy is (its Solve ref: BuildKit's job ID, the gateway's build ID): the
// host's socket ("") or a delegated socket's owner.
type dockerBuildRefs struct {
	mu      sync.Mutex
	viewers map[string]string
	// held counts each delegated socket's refs in viewers.
	held map[string]int
	// claimed is closed and dropped when a build is recorded, for waiters.
	claimed chan struct{}
}

// claim records ref as viewer's build for as long as its Solve runs (and
// buildkitRefGrace after: call the returned release when it returns). It
// refuses a ref that is another socket's build, and on a delegated socket
// one past its buildkitRefsPerSocket.
func (b *dockerBuildRefs) claim(ref, viewer string) (release func(), err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	held, taken := b.viewers[ref]
	if taken && held != viewer {
		return nil, status.Error(codes.AlreadyExists, "the build ref is another build's")
	}
	if !taken {
		if viewer != "" && b.held[viewer] >= buildkitRefsPerSocket {
			return nil, status.Errorf(codes.ResourceExhausted,
				"this Docker socket has %d builds running or just finished; start the next once one has ended", buildkitRefsPerSocket)
		}
		if b.viewers == nil {
			b.viewers = map[string]string{}
		}
		if b.held == nil {
			b.held = map[string]int{}
		}
		b.viewers[ref] = viewer
		if viewer != "" {
			b.held[viewer]++
		}
		if b.claimed != nil {
			close(b.claimed)
			b.claimed = nil
		}
	}
	return func() { time.AfterFunc(buildkitRefGrace, func() { b.forget(ref, viewer) }) }, nil
}

// forget drops ref, when it is still viewer's build.
func (b *dockerBuildRefs) forget(ref, viewer string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if held, known := b.viewers[ref]; !known || held != viewer {
		return
	}
	delete(b.viewers, ref)
	if viewer != "" {
		if b.held[viewer]--; b.held[viewer] <= 0 {
			delete(b.held, viewer)
		}
	}
}

// owns reports whether ref is viewer's build, waiting up to wait for its
// Solve to arrive when it is no socket's yet.
func (b *dockerBuildRefs) owns(ctx context.Context, ref, viewer string, wait time.Duration) bool {
	if ref == "" {
		return false
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		b.mu.Lock()
		held, known := b.viewers[ref]
		if known {
			b.mu.Unlock()
			return held == viewer
		}
		if b.claimed == nil {
			b.claimed = make(chan struct{})
		}
		claimed := b.claimed
		b.mu.Unlock()
		select {
		case <-claimed:
		case <-timer.C:
			return false
		case <-ctx.Done():
			return false
		}
	}
}

type dockerBuildSolver struct {
	control.UnimplementedControlServer
	backend control.ControlClient
	node    node
	// viewer is the delegated socket's owner ("" for the host's socket) and
	// builds whose each build is.
	viewer string
	builds *dockerBuildRefs
}

// Status streams a build's progress; on a delegated socket only its own
// build's (serveDockerBuildControl).
func (s dockerBuildSolver) Status(req *control.StatusRequest, stream grpc.ServerStreamingServer[control.StatusResponse]) error {
	ctx := stream.Context()
	if s.viewer != "" && !s.builds.owns(ctx, req.GetRef(), s.viewer, buildkitRefWait) {
		return status.Error(codes.NotFound, "no such build on this Docker socket")
	}
	md, _ := metadata.FromIncomingContext(ctx)
	up, err := s.backend.Status(metadata.NewOutgoingContext(ctx, buildkitMetadata(md)), req)
	if err != nil {
		return err
	}
	if header, err := up.Header(); err == nil {
		_ = stream.SetHeader(buildkitMetadata(header))
	}
	for {
		msg, err := up.Recv()
		if errors.Is(err, io.EOF) {
			stream.SetTrailer(buildkitMetadata(up.Trailer()))
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(msg); err != nil {
			return err
		}
	}
}

func dockerImageExporter(kind *string, attrs *map[string]string) ([]string, error) {
	if *kind != "moby" {
		return nil, nil
	}
	*kind = "image"
	if *attrs == nil {
		*attrs = make(map[string]string)
	}
	(*attrs)["unpack"] = "true"
	if _, set := (*attrs)["dangling-name-prefix"]; !set {
		(*attrs)["dangling-name-prefix"] = "moby-dangling"
	}
	// BuildKit v0.34 uses this spelling for OptKeyDanglingEmptyOnly.
	(*attrs)["danging-name-empty-only"] = "true"
	// CRI and Docker address the canonical containerd image record. Leaving
	// "repo:tag" in the store publishes an image that tag-based inspect cannot open.
	names := (*attrs)["name"]
	tags := make([]string, 0)
	for _, raw := range strings.Split(names, ",") {
		if raw == "" {
			continue
		}
		tag, err := destinationImageTag(raw, "")
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "invalid build image tag %q", raw)
		}
		if !slices.Contains(tags, tag.String()) {
			tags = append(tags, tag.String())
		}
	}
	(*attrs)["name"] = strings.Join(tags, ",")
	if store, err := strconv.ParseBool((*attrs)["store"]); err == nil && !store {
		return nil, nil
	}
	return tags, nil
}

// The grpc client supplies transport metadata for the upstream connection.
func buildkitMetadata(md metadata.MD) metadata.MD {
	out := md.Copy()
	for key := range out {
		if strings.HasPrefix(key, ":") || strings.HasPrefix(key, "grpc-") ||
			key == "content-type" || key == "user-agent" || key == "te" {
			delete(out, key)
		}
	}
	return out
}

func (s dockerBuildSolver) Solve(ctx context.Context, req *control.SolveRequest) (*control.SolveResponse, error) {
	ref := req.GetRef()
	if s.builds != nil && s.viewer != "" {
		if ref == "" {
			return nil, status.Error(codes.InvalidArgument, "a build on a container's Docker socket needs its own ref")
		}
		if len(ref) > buildkitMaxRef {
			return nil, status.Errorf(codes.InvalidArgument, "a build ref on a container's Docker socket is at most %d bytes", buildkitMaxRef)
		}
	}
	// What the proxy refuses, it refuses before it records the build, so a
	// refused Solve holds no ref: every claimed one reaches buildkitd.
	tags, err := dockerImageExporter(&req.ExporterDeprecated, &req.ExporterAttrsDeprecated)
	if err != nil {
		return nil, err
	}
	if len(req.Exporters) > 0 {
		tags = nil
	}
	for _, exporter := range req.Exporters {
		if exporter != nil {
			current, err := dockerImageExporter(&exporter.Type, &exporter.Attrs)
			if err != nil {
				return nil, err
			}
			if len(req.Exporters) == 1 {
				tags = current
			}
		}
	}
	if s.builds != nil && ref != "" {
		if s.viewer != "" {
			known, err := s.knownToBuildkit(ctx, ref)
			if err != nil {
				return nil, status.Errorf(codes.Unavailable, "look the build ref up in BuildKit: %v", err)
			}
			if known {
				return nil, status.Error(codes.AlreadyExists, "the build ref is another build's")
			}
		}
		release, err := s.builds.claim(ref, s.viewer)
		if err != nil {
			return nil, err
		}
		defer release()
	}
	md, _ := metadata.FromIncomingContext(ctx)
	var header, trailer metadata.MD
	result, err := s.backend.Solve(metadata.NewOutgoingContext(ctx, buildkitMetadata(md)), req,
		grpc.Header(&header), grpc.Trailer(&trailer))
	_ = grpc.SetHeader(ctx, buildkitMetadata(header))
	grpc.SetTrailer(ctx, buildkitMetadata(trailer))
	// A successful native single-platform load is immediately usable by the next
	// Docker request, including when the same tag previously named another image.
	platform := req.FrontendAttrs["platform"]
	local := platform == "" || platform == runtime.GOOS+"/"+runtime.GOARCH
	if err == nil && local && tags != nil {
		if err := s.finishLocalLoad(ctx, tags, result.GetExporterResponse()); err != nil {
			return nil, status.Error(codes.Unavailable, err.Error())
		}
	}
	return result, err
}

// knownToBuildkit reports whether buildkitd has a build of ref, running or
// in its history. The ref table forgets a build buildkitRefGrace after its
// Solve, and never records one through the raw BuildKit bridge
// (serveBuildKit), while buildkitd's Status of a ref replays that build's
// whole log from its history; so a delegated socket that learned such a ref
// may not take it.
//
// The look-up names no ref to buildkitd (BuildHistoryRequest.Ref). Its
// Listen of a ref counts a listener of it and leaves the ref's count, at
// zero, once that listener is gone; a record whose ref has a count is only
// marked deleted, never removed, by a history rm or by buildkitd's own age
// and count limits, and nothing later removes it (a Listen of a deleted ref
// is refused), so the record and the blobs its lease holds stayed until
// buildkitd restarted, for every delegated build (BuildKit v0.26 and v0.34,
// solver/llbsolver/history: Queue.Listen and Queue.delete). The look-up
// lists the history instead: filtered to ref when the filter syntax takes it
// as it is (buildkitFilterableRef), which only narrows what is sent, since
// buildkitd sends every running build whatever the filter; the match is the
// ref itself. What this cannot see is a record buildkitd has marked deleted
// but kept because another client's Listen of its ref holds it: the history
// hides it, while its Status still replays its log.
func (s dockerBuildSolver) knownToBuildkit(ctx context.Context, ref string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req := &control.BuildHistoryRequest{EarlyExit: true}
	if buildkitFilterableRef(ref) {
		req.Filter = []string{"ref==" + ref}
	}
	records, err := s.backend.ListenBuildHistory(ctx, req)
	if err != nil {
		return false, err
	}
	for {
		event, err := records.Recv()
		if errors.Is(err, io.EOF) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		if event.GetRecord().GetRef() == ref {
			return true, nil
		}
	}
}

// buildkitFilterableRef reports whether ref can stand unquoted as the value
// of a history filter (ref==<ref>): BuildKit's own refs (25 characters of
// [a-z0-9]) can. Another is looked up in the whole history.
func buildkitFilterableRef(ref string) bool {
	if ref == "" {
		return false
	}
	for _, r := range ref {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func (s dockerBuildSolver) finishLocalLoad(ctx context.Context, tags []string, response map[string]string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	id := response["containerimage.config.digest"]
	if !fullDockerImageID(id) {
		raw, err := base64.StdEncoding.DecodeString(response["containerimage.descriptor"])
		if err != nil {
			return err
		}
		if len(raw) == 0 {
			return nil
		}
		var desc ocispec.Descriptor
		if err := json.Unmarshal(raw, &desc); err != nil {
			return err
		}
		if !fullDockerImageID(desc.Digest.String()) || response["containerimage.digest"] != desc.Digest.String() {
			return errors.New("BuildKit result descriptor and manifest digest differ")
		}
		switch desc.MediaType {
		case ocispec.MediaTypeImageManifest, "application/vnd.docker.distribution.manifest.v2+json":
			id, err = s.node.manifestConfigID(imageMetadataContext(ctx), &types.Descriptor{
				MediaType: desc.MediaType, Size: desc.Size, Digest: desc.Digest.String(),
			})
		case ocispec.MediaTypeImageIndex, "application/vnd.docker.distribution.manifest.list.v2+json":
			// A provenance attestation adds a second manifest. CRI records the
			// runnable config it selected for the local platform on this index.
			err = waitForDockerImageIndex(ctx, func(visible context.Context) (bool, error) {
				record, err := s.node.dockerConfigRecordForTarget(imageMetadataContext(visible), desc.Digest.String())
				if record != nil && (record.GetTarget().GetMediaType() != desc.MediaType || record.GetTarget().GetSize() != desc.Size) {
					return false, errors.New("published index and local image descriptor differ")
				}
				id = record.GetName()
				return id != "", err
			})
		default:
			return nil
		}
		if err != nil {
			return err
		}
		// Older clients consume the config ID. The containerd-aware Buildx
		// driver selects the manifest digest. Both must resolve locally.
		response["containerimage.config.digest"] = id
	}
	if len(tags) == 0 {
		return s.node.waitForDockerImageTag(ctx, "", id)
	}
	for _, tag := range tags {
		if err := s.node.waitForDockerImageTag(ctx, tag, id); err != nil {
			return err
		}
	}
	return nil
}

// The session HTTP/2 connection runs in the reverse direction. BuildKit calls
// the client to read the context and deliver local exports over Control.Session.
func serveDockerBuildSession(r *http.Request, client net.Conn, bk control.ControlClient) {
	md := metadata.MD{}
	for key, values := range r.Header {
		key = strings.ToLower(key)
		if strings.HasPrefix(key, "x-docker-expose-session-") || strings.HasPrefix(key, "x-buildkit-session-") {
			md[key] = values
		}
	}
	ctx, cancel := context.WithCancel(metadata.NewOutgoingContext(r.Context(), md))
	defer cancel()
	stream, err := bk.Session(ctx)
	if err != nil {
		return
	}
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			buf := make([]byte, 32<<10)
			n, readErr := client.Read(buf)
			if n > 0 {
				if err := stream.Send(&control.BytesMessage{Data: buf[:n]}); err != nil {
					cancel()
					return
				}
			}
			if readErr != nil {
				if !errors.Is(readErr, io.EOF) || stream.CloseSend() != nil {
					cancel()
				}
				return
			}
		}
	}()
	for {
		msg, err := stream.Recv()
		if err != nil {
			break
		}
		if _, err := client.Write(msg.Data); err != nil {
			break
		}
	}
	cancel()
	client.Close()
	<-finished
}
