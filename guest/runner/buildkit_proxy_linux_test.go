package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/containerd/containerd/filters"
	control "github.com/moby/buildkit/api/services/control"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// The fake upstream decodes the known BuildKit RPCs using their real generated
// bindings. Its generic probe accepts an opaque stream to test forwarding.
type buildkitTestCodec struct{}

func (buildkitTestCodec) Marshal(v any) ([]byte, error) { return *v.(*[]byte), nil }
func (buildkitTestCodec) Unmarshal(b []byte, v any) error {
	*v.(*[]byte) = append([]byte(nil), b...)
	return nil
}
func (buildkitTestCodec) Name() string { return "proto" }

type fakeBuildkit struct {
	mu     sync.Mutex
	calls  map[string]metadata.MD
	counts map[string]int
	solve  *control.SolveRequest
	// known are the refs of the builds it has (every ref it solved), which
	// ListenBuildHistory lists. listening and deleted are BuildKit's own
	// (solver/llbsolver/history, Queue.Listen and Queue.delete, v0.26 and
	// v0.34): a Listen of a ref counts in listening and leaves the ref there,
	// at zero, after it; a deletion of a record whose ref is there only marks
	// it deleted, and the last listener of a deleted ref to end removes it.
	known     map[string]bool
	listening map[string]int
	deleted   map[string]bool
	// filters is the Filter of every ListenBuildHistory.
	filters [][]string
}

// listenHistory answers a ListenBuildHistory as buildkitd's history queue
// does for the records it has (it has no running builds): EarlyExit, the
// filters in containerd's syntax.
func (f *fakeBuildkit) listenHistory(req *control.BuildHistoryRequest, ss grpc.ServerStream) error {
	filter, err := filters.ParseAll(req.Filter...)
	if err != nil {
		return status.Error(codes.InvalidArgument, err.Error())
	}
	f.mu.Lock()
	if f.listening == nil {
		f.listening, f.deleted = map[string]int{}, map[string]bool{}
	}
	f.filters = append(f.filters, req.Filter)
	if ref := req.Ref; ref != "" {
		if f.deleted[ref] {
			f.mu.Unlock()
			return status.Errorf(codes.NotFound, "ref %s is deleted", ref)
		}
		f.listening[ref]++
		defer func() {
			f.mu.Lock()
			f.listening[ref]--
			if f.deleted[ref] && f.listening[ref] == 0 {
				delete(f.listening, ref)
				f.deleteLocked(ref)
			}
			f.mu.Unlock()
		}()
	}
	var refs []string
	for ref := range f.known {
		if (req.Ref == "" || ref == req.Ref) && !f.deleted[ref] {
			refs = append(refs, ref)
		}
	}
	f.mu.Unlock()
	slices.Sort(refs)
	for _, ref := range refs {
		if !filter.Match(filters.AdapterFunc(func(path []string) (string, bool) {
			return ref, len(path) == 1 && path[0] == "ref"
		})) {
			continue
		}
		resp, err := proto.Marshal(&control.BuildHistoryEvent{Type: control.BuildHistoryEventType_COMPLETE,
			Record: &control.BuildHistoryRecord{Ref: ref}})
		if err != nil {
			return err
		}
		if err := ss.SendMsg(&resp); err != nil {
			return err
		}
	}
	return nil
}

// deleteHistory deletes the record of ref as buildkitd's history queue does.
func (f *fakeBuildkit) deleteHistory(ref string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, listened := f.listening[ref]; listened {
		f.deleted[ref] = true
		return
	}
	f.deleteLocked(ref)
}

func (f *fakeBuildkit) deleteLocked(ref string) {
	delete(f.known, ref)
	delete(f.deleted, ref)
}

// count is how many times method reached the fake.
func (f *fakeBuildkit) count(method string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.counts[method]
}

func (f *fakeBuildkit) handle(_ any, ss grpc.ServerStream) error {
	method, _ := grpc.MethodFromServerStream(ss)
	md, _ := metadata.FromIncomingContext(ss.Context())
	f.mu.Lock()
	f.calls[method] = md
	if f.counts == nil {
		f.counts = map[string]int{}
	}
	f.counts[method]++
	f.mu.Unlock()
	switch method {
	case control.Control_Status_FullMethodName:
		var b []byte
		if err := ss.RecvMsg(&b); err != nil {
			return err
		}
		var req control.StatusRequest
		if err := proto.Unmarshal(b, &req); err != nil {
			return err
		}
		resp, err := proto.Marshal(&control.StatusResponse{Logs: []*control.VertexLog{{Msg: []byte("log of " + req.Ref)}}})
		if err != nil {
			return err
		}
		return ss.SendMsg(&resp)
	case control.Control_Solve_FullMethodName:
		var b []byte
		if err := ss.RecvMsg(&b); err != nil {
			return err
		}
		var req control.SolveRequest
		if err := proto.Unmarshal(b, &req); err != nil {
			return err
		}
		f.mu.Lock()
		f.solve = &req
		if f.known == nil {
			f.known = map[string]bool{}
		}
		f.known[req.Ref] = true
		f.mu.Unlock()
		_ = ss.SetHeader(metadata.Pairs("x-up-header", "h1"))
		ss.SetTrailer(metadata.Pairs("x-up-trailer", "t1"))
		resp, err := proto.Marshal(&control.SolveResponse{ExporterResponse: map[string]string{"test": "solved"}})
		if err != nil {
			return err
		}
		return ss.SendMsg(&resp)
	case control.Control_ListenBuildHistory_FullMethodName:
		var b []byte
		if err := ss.RecvMsg(&b); err != nil {
			return err
		}
		var req control.BuildHistoryRequest
		if proto.Unmarshal(b, &req) != nil {
			return ss.SendMsg(&b) // a probe of opaque bytes is echoed
		}
		return f.listenHistory(&req, ss)
	case control.Control_UpdateBuildHistory_FullMethodName:
		var b []byte
		if err := ss.RecvMsg(&b); err != nil {
			return err
		}
		var req control.UpdateBuildHistoryRequest
		if proto.Unmarshal(b, &req) != nil {
			return ss.SendMsg(&b) // a probe of opaque bytes is echoed
		}
		if req.Delete {
			f.deleteHistory(req.Ref)
		}
		resp, err := proto.Marshal(&control.UpdateBuildHistoryResponse{})
		if err != nil {
			return err
		}
		return ss.SendMsg(&resp)
	case "/test.Echo/Fail":
		return status.Error(codes.NotFound, "nope")
	case control.Control_Session_FullMethodName:
		for {
			var b []byte
			if err := ss.RecvMsg(&b); errors.Is(err, io.EOF) {
				return nil
			} else if err != nil {
				return err
			}
			var req control.BytesMessage
			if err := proto.Unmarshal(b, &req); err != nil {
				return err
			}
			out, err := proto.Marshal(&control.BytesMessage{Data: bytes.ToUpper(req.Data)})
			if err != nil {
				return err
			}
			if err := ss.SendMsg(&out); err != nil {
				return err
			}
		}
	default:
		for {
			var b []byte
			if err := ss.RecvMsg(&b); errors.Is(err, io.EOF) {
				return nil
			} else if err != nil {
				return err
			}
			out := bytes.ToUpper(b)
			if err := ss.SendMsg(&out); err != nil {
				return err
			}
		}
	}
}

// proxyHarness runs a fake buildkitd, the engine's /grpc and /session upgrade
// handler in front of it, and dials the handler the way buildx does.
type proxyHarness struct {
	up     *fakeBuildkit
	sock   string
	engine *dockerEngine
	dir    string
}

func newProxyHarness(t *testing.T) *proxyHarness {
	t.Helper()
	dir := t.TempDir()
	h := &proxyHarness{up: &fakeBuildkit{calls: map[string]metadata.MD{}}, sock: filepath.Join(dir, "docker.sock")}
	upSock := filepath.Join(dir, "buildkitd.sock")
	ul, err := net.Listen("unix", upSock)
	if err != nil {
		t.Fatal(err)
	}
	upstream := grpc.NewServer(grpc.UnknownServiceHandler(h.up.handle), grpc.ForceServerCodec(buildkitTestCodec{}))
	go upstream.Serve(ul)
	t.Cleanup(upstream.Stop)
	pl, err := net.Listen("unix", h.sock)
	if err != nil {
		t.Fatal(err)
	}
	h.engine, h.dir = &dockerEngine{buildkitSocket: upSock}, dir
	srv := &http.Server{ReadTimeout: 30 * time.Second, Handler: h.engine}
	go srv.Serve(pl)
	t.Cleanup(func() { srv.Close() })
	return h
}

// delegated is a harness on the same engine and fake buildkitd whose socket
// is viewer's delegated one.
func (h *proxyHarness) delegated(t *testing.T, viewer string) *proxyHarness {
	t.Helper()
	d := &proxyHarness{up: h.up, sock: filepath.Join(h.dir, viewer[:8]+".sock"), engine: h.engine, dir: h.dir}
	pl, err := net.Listen("unix", d.sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{ReadTimeout: 30 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.engine.ServeHTTP(w, r.WithContext(withViewer(r.Context(), viewer)))
	})}
	go srv.Serve(pl)
	t.Cleanup(func() { srv.Close() })
	return d
}

// upgrade sends what the Docker client's DialHijack sends and returns the
// switched connection, or the refusal.
func (h *proxyHarness) upgrade(t *testing.T, path string, header http.Header) (net.Conn, *http.Response) {
	t.Helper()
	conn, err := net.Dial("unix", h.sock)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("POST", "http://docker"+path, nil)
	for k, v := range header {
		req.Header[k] = v
	}
	if req.Header.Get("Upgrade") == "" {
		req.Header.Set("Upgrade", "h2c")
	}
	req.Header.Set("Connection", "Upgrade")
	if err := req.Write(conn); err != nil {
		t.Fatal(err)
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		conn.Close()
		return nil, resp
	}
	if resp.Header.Get("Upgrade") != "h2c" {
		t.Fatalf("101 without Upgrade: h2c: %v", resp.Header)
	}
	return buildkitClientConn{conn, br}, resp
}

func (h *proxyHarness) client(t *testing.T) *grpc.ClientConn {
	t.Helper()
	conn, _ := h.upgrade(t, "/grpc", nil)
	if conn == nil {
		t.Fatal("upgrade refused")
	}
	used := false
	cc, err := grpc.NewClient("passthrough:///docker", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			if used {
				return nil, errors.New("the hijacked connection is gone")
			}
			used = true
			return conn, nil
		}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cc.Close() })
	return cc
}

func TestGRPCProxyForwardsAndRewritesSolve(t *testing.T) {
	h := newProxyHarness(t)
	cc := h.client(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ctx = metadata.AppendToOutgoingContext(ctx, "x-client-md", "v1")

	req := &control.SolveRequest{Ref: "r1", ExporterDeprecated: "moby", ExporterAttrsDeprecated: map[string]string{"name": "app:1"},
		Exporters: []*control.Exporter{{Type: "moby", Attrs: map[string]string{"name": "app:1"}}}}
	var header, trailer metadata.MD
	result, err := control.NewControlClient(cc).Solve(ctx, req, grpc.Header(&header), grpc.Trailer(&trailer))
	if err != nil {
		t.Fatal(err)
	}
	if result.GetExporterResponse()["test"] != "solved" {
		t.Fatalf("Solve response %v", result)
	}
	if !slices.Equal(header.Get("x-up-header"), []string{"h1"}) || !slices.Equal(trailer.Get("x-up-trailer"), []string{"t1"}) {
		t.Fatalf("upstream header %v / trailer %v", header, trailer)
	}
	h.up.mu.Lock()
	got := h.up.solve
	md := h.up.calls[control.Control_Solve_FullMethodName]
	h.up.mu.Unlock()
	if got.GetExporterDeprecated() != "image" || len(got.GetExporters()) != 1 || got.Exporters[0].Type != "image" ||
		got.Exporters[0].Attrs["name"] != "docker.io/library/app:1" || got.GetExporterAttrsDeprecated()["unpack"] != "true" {
		t.Fatalf("upstream received %+v", got)
	}
	if v := md.Get("x-client-md"); len(v) != 1 || v[0] != "v1" {
		t.Fatalf("client metadata not forwarded: %v", md)
	}

	// Any other service passes through byte for byte, as a bidirectional stream.
	stream, err := cc.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, "/moby.buildkit.v1.frontend.LLBBridge/Ping", grpc.ForceCodec(buildkitTestCodec{}))
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"a\x00b", "cd", strings.Repeat("e", 3<<20)} {
		msg := []byte(s)
		if err := stream.SendMsg(&msg); err != nil {
			t.Fatal(err)
		}
		var echo []byte
		if err := stream.RecvMsg(&echo); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(echo, bytes.ToUpper(msg)) {
			t.Fatalf("echo of %d bytes differs", len(msg))
		}
	}
	if err := stream.CloseSend(); err != nil {
		t.Fatal(err)
	}
	var tail []byte
	if err := stream.RecvMsg(&tail); !errors.Is(err, io.EOF) {
		t.Fatalf("stream end: %v", err)
	}

	// An upstream status reaches the client unchanged.
	var reqBytes, resp []byte
	err = cc.Invoke(ctx, "/test.Echo/Fail", &reqBytes, &resp, grpc.ForceCodec(buildkitTestCodec{}))
	if st, _ := status.FromError(err); st.Code() != codes.NotFound || st.Message() != "nope" {
		t.Fatalf("upstream error became %v", err)
	}
}

func TestSessionBridge(t *testing.T) {
	h := newProxyHarness(t)
	conn, resp := h.upgrade(t, "/session", http.Header{
		"X-Docker-Expose-Session-Uuid":             {"u1"},
		"X-Docker-Expose-Session-Sharedkey":        {"k1"},
		"X-Docker-Expose-Session-Grpc-Method":      {"/moby.filesync.v1.FileSync/DiffCopy", "/grpc.health.v1.Health/Check"},
		"X-Buildkit-Session-Health-Custom-Timeout": {"30s"},
		"X-Unrelated": {"no"},
	})
	if conn == nil {
		t.Fatalf("session upgrade refused: %s", resp.Status)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	big := bytes.Repeat([]byte("xy"), 100<<10) // spans several 32 KiB frames
	go func() { conn.Write([]byte("hello")); conn.Write(big) }()
	want := append([]byte("HELLO"), bytes.ToUpper(big)...)
	got := make([]byte, len(want))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("session bytes changed in transit")
	}
	h.up.mu.Lock()
	md := h.up.calls[control.Control_Session_FullMethodName]
	h.up.mu.Unlock()
	if md.Get("x-docker-expose-session-uuid")[0] != "u1" || md.Get("x-docker-expose-session-sharedkey")[0] != "k1" ||
		!slices.Equal(md.Get("x-docker-expose-session-grpc-method"), []string{"/moby.filesync.v1.FileSync/DiffCopy", "/grpc.health.v1.Health/Check"}) ||
		!slices.Equal(md.Get("x-buildkit-session-health-custom-timeout"), []string{"30s"}) || len(md.Get("x-unrelated")) != 0 {
		t.Fatalf("session metadata %v", md)
	}
	// The client's half-close ends the upstream session, which closes the connection.
	if err := conn.(buildkitClientConn).Conn.(*net.UnixConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if n, err := conn.Read(make([]byte, 1)); n != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("after half-close: n=%d err=%v", n, err)
	}
}

func TestUpgradeRequiresH2C(t *testing.T) {
	h := newProxyHarness(t)
	for _, path := range []string{"/grpc", "/session"} {
		conn, resp := h.upgrade(t, path, http.Header{"Upgrade": {"tcp"}})
		if conn != nil || resp.StatusCode != 400 {
			t.Fatalf("%s with Upgrade: tcp answered %v", path, resp.Status)
		}
	}
}

func TestExtraRoutesAndVersionCapabilities(t *testing.T) {
	saved := extraRoutes
	t.Cleanup(func() { extraRoutes = saved })
	var seen []string
	extraRoutes = append(extraRoutes[:len(extraRoutes):len(extraRoutes)],
		func(_ *dockerEngine, w http.ResponseWriter, _ *http.Request, method, path string) (bool, error) {
			seen = append(seen, method+" "+path)
			if path == "micropod/test-route" {
				writeJSON(w, 200, map[string]string{"route": "first"})
				return true, nil
			}
			return false, nil
		},
		func(_ *dockerEngine, w http.ResponseWriter, _ *http.Request, _, path string) (bool, error) {
			if path == "micropod/test-route" {
				t.Error("a later route ran after an earlier one handled the request")
			}
			if path == "micropod/test-error" {
				return true, fail(418, "teapot")
			}
			return false, nil
		})
	s := &dockerEngine{}
	call := func(target string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, httptest.NewRequest("GET", target, nil))
		return rec
	}
	if rec := call("/v1.47/micropod/test-route"); rec.Code != 200 || !strings.Contains(rec.Body.String(), "first") {
		t.Fatalf("route: %d %s", rec.Code, rec.Body)
	}
	if rec := call("/micropod/test-error"); rec.Code != 418 || !strings.Contains(rec.Body.String(), "teapot") {
		t.Fatalf("route error: %d %s", rec.Code, rec.Body)
	}
	if rec := call("/v1.44/nothing/here"); rec.Code != 501 {
		t.Fatalf("unrouted request: %d %s", rec.Code, rec.Body)
	}
	if !slices.Equal(seen, []string{"GET micropod/test-route", "GET micropod/test-error", "GET nothing/here"}) {
		t.Fatalf("routes saw %v", seen)
	}

	for _, socket := range []string{"", "/local/buildkit.sock"} {
		s.buildkitSocket = socket
		if ping := call("/_ping"); (ping.Header().Get("Builder-Version") == "2") != (socket != "") {
			t.Fatalf("socket %q: Builder-Version %q", socket, ping.Header().Get("Builder-Version"))
		}
		var version struct {
			GitCommit            string
			MicropodCapabilities []string
		}
		if err := json.Unmarshal(call("/version").Body.Bytes(), &version); err != nil {
			t.Fatal(err)
		}
		if version.GitCommit != engineCommit || !slices.Equal(version.MicropodCapabilities, engineCapabilities(socket != "")) {
			t.Fatalf("socket %q: version %+v", socket, version)
		}
	}
	if !slices.Equal(engineCapabilities(true), []string{"caches", "buildkit", "grpc-build"}) || !slices.Equal(engineCapabilities(false), []string{"caches"}) {
		t.Fatal("capability lists changed")
	}
}

// What a delegated socket can make the engine keep of its builds is bounded:
// a Solve the proxy refuses records no build (and so reaches no build's
// progress), a ref longer than buildkitMaxRef is refused before anything,
// and a socket holds at most buildkitRefsPerSocket refs, while another
// socket and the host's are not held to its count.
func TestADelegatedSocketsBuildRefsAreBounded(t *testing.T) {
	old := buildkitRefWait
	buildkitRefWait = 200 * time.Millisecond
	t.Cleanup(func() { buildkitRefWait = old })
	host := newProxyHarness(t)
	a := control.NewControlClient(host.delegated(t, strings.Repeat("a", 64)).client(t))
	b := control.NewControlClient(host.delegated(t, strings.Repeat("b", 64)).client(t))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	code := func(err error) codes.Code { st, _ := status.FromError(err); return st.Code() }
	refs := func() int {
		host.engine.builds.mu.Lock()
		defer host.engine.builds.mu.Unlock()
		return len(host.engine.builds.viewers)
	}

	bad := []*control.Exporter{{Type: "moby", Attrs: map[string]string{"name": "Bad Tag!"}}}
	if _, err := a.Solve(ctx, &control.SolveRequest{Ref: "refused", Exporters: bad}); code(err) != codes.InvalidArgument {
		t.Fatalf("a Solve with an invalid image name: %v", err)
	}
	if n := refs(); n != 0 {
		t.Errorf("a refused Solve left %d build refs", n)
	}
	stream, err := a.Status(ctx, &control.StatusRequest{Ref: "refused"})
	if err == nil {
		_, err = stream.Recv()
	}
	if code(err) != codes.NotFound || host.up.count(control.Control_Status_FullMethodName) != 0 {
		t.Errorf("the progress of a refused Solve's ref: %v", err)
	}
	if _, err := a.Solve(ctx, &control.SolveRequest{Ref: strings.Repeat("r", 1<<20)}); code(err) != codes.InvalidArgument {
		t.Errorf("a Solve with a 1 MiB ref: %v", err)
	}
	if n := host.up.count(control.Control_Solve_FullMethodName); n != 0 || refs() != 0 {
		t.Fatalf("refused Solves reached buildkitd %d times and left %d refs", n, refs())
	}

	for i := range buildkitRefsPerSocket {
		if _, err := a.Solve(ctx, &control.SolveRequest{Ref: fmt.Sprintf("a-%d", i)}); err != nil {
			t.Fatalf("build %d of a socket: %v", i, err)
		}
	}
	if _, err := a.Solve(ctx, &control.SolveRequest{Ref: "one-too-many"}); code(err) != codes.ResourceExhausted {
		t.Errorf("a socket's build past %d: %v", buildkitRefsPerSocket, err)
	}
	if _, err := b.Solve(ctx, &control.SolveRequest{Ref: "b-1"}); err != nil {
		t.Errorf("another socket's build: %v", err)
	}
	if _, err := control.NewControlClient(host.client(t)).Solve(ctx, &control.SolveRequest{Ref: "host-1"}); err != nil {
		t.Errorf("the host's build: %v", err)
	}
	if n := refs(); n != buildkitRefsPerSocket+2 {
		t.Errorf("%d build refs recorded, want %d", n, buildkitRefsPerSocket+2)
	}
}

// A delegated socket cannot take the ref of a build buildkitd already has,
// which the ref table does not hold: one another socket's Solve ran more
// than buildkitRefGrace ago, or one through the raw BuildKit bridge. Its
// Solve under that ref is refused, and so that build's progress (a finished
// build's whole log, replayed from the history) is not there for Status.
func TestADelegatedSocketCannotTakeARefBuildkitAlreadyHas(t *testing.T) {
	old := buildkitRefWait
	buildkitRefWait = 200 * time.Millisecond
	t.Cleanup(func() { buildkitRefWait = old })
	host := newProxyHarness(t)
	host.up.mu.Lock()
	// One ref a history filter takes as it is, and one it would not.
	unfilterable := `raw bridge, "build"==x`
	host.up.known = map[string]bool{"raw-bridge-build": true, unfilterable: true}
	host.up.mu.Unlock()
	a := control.NewControlClient(host.delegated(t, strings.Repeat("a", 64)).client(t))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := func(err error) codes.Code { st, _ := status.FromError(err); return st.Code() }

	for _, ref := range []string{"raw-bridge-build", unfilterable} {
		if _, err := a.Solve(ctx, &control.SolveRequest{Ref: ref}); code(err) != codes.AlreadyExists {
			t.Errorf("a Solve under the ref of a build buildkitd has (%q): %v, want AlreadyExists", ref, err)
		}
	}
	stream, err := a.Status(ctx, &control.StatusRequest{Ref: "raw-bridge-build"})
	if err == nil {
		_, err = stream.Recv()
	}
	if code(err) != codes.NotFound {
		t.Errorf("the progress of a build buildkitd has: %v, want NotFound", err)
	}
	if n, m := host.up.count(control.Control_Solve_FullMethodName), host.up.count(control.Control_Status_FullMethodName); n != 0 || m != 0 {
		t.Errorf("Solve reached buildkitd %d times and Status %d, want neither", n, m)
	}
	// A ref of its own is its own, and the match is the whole ref.
	for _, ref := range []string{"fresh", "raw-bridge", `raw bridge, "build"`} {
		if _, err := a.Solve(ctx, &control.SolveRequest{Ref: ref}); err != nil {
			t.Fatalf("a Solve under a ref buildkitd does not have (%q): %v", ref, err)
		}
	}
	stream, err = a.Status(ctx, &control.StatusRequest{Ref: "fresh"})
	if err == nil {
		_, err = stream.Recv()
	}
	if err != nil {
		t.Errorf("its own build's progress: %v", err)
	}
	host.up.mu.Lock()
	sent := slices.Clone(host.up.filters)
	host.up.mu.Unlock()
	want := [][]string{{"ref==raw-bridge-build"}, nil, {"ref==fresh"}, {"ref==raw-bridge"}, nil}
	if !slices.EqualFunc(sent, want, slices.Equal) {
		t.Errorf("the look-ups filtered the history by %q, want %q", sent, want)
	}
}

// A delegated build's history record goes like any other build's, by a
// history rm (and buildkitd's own age and count limits, which delete the same
// way): the look-up of its ref before its Solve names no ref to buildkitd. A
// Listen of a ref leaves the ref counted as listened to, and buildkitd then
// only marks its record deleted, keeping it and the blobs its lease holds
// until buildkitd restarts.
func TestADelegatedBuildsHistoryRecordCanBeDeleted(t *testing.T) {
	host := newProxyHarness(t)
	a := control.NewControlClient(host.delegated(t, strings.Repeat("a", 64)).client(t))
	hc := control.NewControlClient(host.client(t))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, ref := range []string{"k3xq9z0m4c2v8b1n6l5j7h0gq", `a ref, "quoted"`} {
		if _, err := a.Solve(ctx, &control.SolveRequest{Ref: ref}); err != nil {
			t.Fatal(err)
		}
		if _, err := hc.UpdateBuildHistory(ctx, &control.UpdateBuildHistoryRequest{Ref: ref, Delete: true}); err != nil {
			t.Fatal(err)
		}
		host.up.mu.Lock()
		kept, marked := host.up.known[ref], host.up.deleted[ref]
		_, listened := host.up.listening[ref]
		host.up.mu.Unlock()
		if kept || marked || listened {
			t.Errorf("after a history rm of the delegated build %q: its record kept %v, marked deleted %v, its ref counted as listened to %v",
				ref, kept, marked, listened)
		}
	}
}

// A ref the look-up filters the history by stands for itself in the filter
// syntax buildkitd parses (containerd's): it matches that ref and no other.
// One that would not is looked up in the whole history.
func TestBuildkitHistoryFilterMatchesTheWholeRef(t *testing.T) {
	field := func(ref string) filters.Adaptor {
		return filters.AdapterFunc(func(path []string) (string, bool) { return ref, len(path) == 1 && path[0] == "ref" })
	}
	for _, ref := range []string{"k3xq9z0m4c2v8b1n6l5j7h0gq", "-x", "_y", "A-b_9", strings.Repeat("z", buildkitMaxRef)} {
		if !buildkitFilterableRef(ref) {
			t.Errorf("%q is not filtered by", ref)
			continue
		}
		filter, err := filters.ParseAll("ref==" + ref)
		if err != nil {
			t.Errorf("the filter of %q: %v", ref, err)
			continue
		}
		if !filter.Match(field(ref)) || filter.Match(field(ref+"z")) || filter.Match(field(ref[1:])) {
			t.Errorf("the filter of %q matches more or less than %q", ref, ref)
		}
	}
	for _, ref := range []string{"", "a,b", "a b", `"a"`, "a.b", "a==b", "a/b", "é"} {
		if buildkitFilterableRef(ref) {
			t.Errorf("%q is filtered by", ref)
		}
	}
}

// On a delegated socket a build is its own job's: another job's build's
// progress, frontend gateway and records, the machine's build history and
// the history's content are not there, while its own build, the cache and
// the workers are. The host's socket still reaches everything.
func TestGRPCProxyKeepsADelegatedSocketToItsOwnBuilds(t *testing.T) {
	old := buildkitRefWait
	buildkitRefWait = 300 * time.Millisecond
	t.Cleanup(func() { buildkitRefWait = old })
	host := newProxyHarness(t)
	a := host.delegated(t, strings.Repeat("a", 64)).client(t)
	b := host.delegated(t, strings.Repeat("b", 64)).client(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := func(err error) codes.Code { st, _ := status.FromError(err); return st.Code() }
	raw := func(cc *grpc.ClientConn, ctx context.Context, method string) error {
		in, out := []byte("q"), []byte(nil)
		return cc.Invoke(ctx, method, &in, &out, grpc.ForceCodec(buildkitTestCodec{}))
	}
	statusOf := func(cc *grpc.ClientConn, ref string) (string, error) {
		stream, err := control.NewControlClient(cc).Status(ctx, &control.StatusRequest{Ref: ref})
		if err != nil {
			return "", err
		}
		msg, err := stream.Recv()
		if err != nil {
			return "", err
		}
		return string(msg.GetLogs()[0].GetMsg()), nil
	}

	if _, err := control.NewControlClient(a).Solve(ctx, &control.SolveRequest{Ref: "build-of-a"}); err != nil {
		t.Fatal(err)
	}
	if got, err := statusOf(a, "build-of-a"); err != nil || got != "log of build-of-a" {
		t.Fatalf("its own build's progress: %q %v", got, err)
	}
	for _, ref := range []string{"build-of-a", "build-of-nobody"} {
		if _, err := statusOf(b, ref); code(err) != codes.NotFound {
			t.Errorf("another job's progress of %s: %v, want NotFound", ref, err)
		}
	}
	if n := host.up.count(control.Control_Status_FullMethodName); n != 1 {
		t.Errorf("Status reached buildkitd %d times, want once (its own)", n)
	}
	if _, err := control.NewControlClient(b).Solve(ctx, &control.SolveRequest{Ref: "build-of-a"}); code(err) != codes.AlreadyExists {
		t.Errorf("a solve under another job's build ref: %v", err)
	}
	gateway := buildkitGatewayService + "Ping"
	if err := raw(a, metadata.AppendToOutgoingContext(ctx, buildkitBuildIDHeader, "build-of-a"), gateway); err != nil {
		t.Errorf("its own build's frontend gateway: %v", err)
	}
	for _, md := range [][]string{{buildkitBuildIDHeader, "build-of-a"}, {}} {
		if err := raw(b, metadata.AppendToOutgoingContext(ctx, md...), gateway); code(err) != codes.NotFound {
			t.Errorf("another job's frontend gateway (%v): %v, want NotFound", md, err)
		}
	}
	if n := host.up.count(gateway); n != 1 {
		t.Errorf("the gateway reached buildkitd %d times, want once (its own)", n)
	}
	for _, method := range []string{control.Control_ListenBuildHistory_FullMethodName, control.Control_UpdateBuildHistory_FullMethodName,
		"/containerd.services.content.v1.Content/Info", "/containerd.services.content.v1.Content/Read",
		"/opentelemetry.proto.collector.trace.v1.TraceService/Export", "/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"} {
		// (The proxy's own Solve looks a delegated socket's ref up in the
		// history; the client's call is what must not get there.)
		before := host.up.count(method)
		if err := raw(b, ctx, method); code(err) != codes.PermissionDenied {
			t.Errorf("%s on a delegated socket: %v, want PermissionDenied", method, err)
		}
		if host.up.count(method) != before {
			t.Errorf("%s reached buildkitd from a delegated socket", method)
		}
	}
	for _, method := range []string{control.Control_ListWorkers_FullMethodName, control.Control_Info_FullMethodName, control.Control_DiskUsage_FullMethodName} {
		if err := raw(b, ctx, method); err != nil {
			t.Errorf("%s on a delegated socket: %v", method, err)
		}
	}
	// The host's socket is the machine's.
	hc := host.client(t)
	if err := raw(hc, ctx, control.Control_ListenBuildHistory_FullMethodName); err != nil {
		t.Errorf("the host's build history: %v", err)
	}
	if got, err := statusOf(hc, "build-of-a"); err != nil || got != "log of build-of-a" {
		t.Errorf("the host's view of a job's build: %q %v", got, err)
	}
}
