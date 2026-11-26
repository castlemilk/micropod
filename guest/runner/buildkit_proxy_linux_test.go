package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
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

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// controlDescriptors builds the SolveRequest and Exporter schema of BuildKit's
// api/services/control/control.proto (v0.34) with the field numbers the
// rewrite depends on, so the protobuf runtime, not the code under test,
// encodes the inputs and decodes the outputs.
func controlDescriptors(t *testing.T) protoreflect.MessageDescriptor {
	t.Helper()
	str := descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum()
	boolean := descriptorpb.FieldDescriptorProto_TYPE_BOOL.Enum()
	message := descriptorpb.FieldDescriptorProto_TYPE_MESSAGE.Enum()
	optional := descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum()
	repeated := descriptorpb.FieldDescriptorProto_LABEL_REPEATED.Enum()
	scalar := func(name string, num int32, typ *descriptorpb.FieldDescriptorProto_Type) *descriptorpb.FieldDescriptorProto {
		return &descriptorpb.FieldDescriptorProto{Name: proto.String(name), JsonName: proto.String(name), Number: proto.Int32(num), Type: typ, Label: optional}
	}
	ref := func(name string, num int32, typeName string) *descriptorpb.FieldDescriptorProto {
		return &descriptorpb.FieldDescriptorProto{Name: proto.String(name), JsonName: proto.String(name), Number: proto.Int32(num), Type: message, Label: repeated, TypeName: proto.String(typeName)}
	}
	entry := func(name string) *descriptorpb.DescriptorProto {
		return &descriptorpb.DescriptorProto{Name: proto.String(name), Options: &descriptorpb.MessageOptions{MapEntry: proto.Bool(true)},
			Field: []*descriptorpb.FieldDescriptorProto{scalar("key", 1, str), scalar("value", 2, str)}}
	}
	file := &descriptorpb.FileDescriptorProto{
		Name: proto.String("control_test.proto"), Package: proto.String("moby.buildkit.v1"), Syntax: proto.String("proto3"),
		MessageType: []*descriptorpb.DescriptorProto{
			{
				Name:       proto.String("Exporter"),
				Field:      []*descriptorpb.FieldDescriptorProto{scalar("Type", 1, str), ref("Attrs", 2, ".moby.buildkit.v1.Exporter.AttrsEntry")},
				NestedType: []*descriptorpb.DescriptorProto{entry("AttrsEntry")},
			},
			{
				Name: proto.String("SolveRequest"),
				Field: []*descriptorpb.FieldDescriptorProto{
					scalar("Ref", 1, str),
					scalar("ExporterDeprecated", 3, str),
					ref("ExporterAttrsDeprecated", 4, ".moby.buildkit.v1.SolveRequest.ExporterAttrsDeprecatedEntry"),
					scalar("Session", 5, str),
					scalar("Frontend", 6, str),
					ref("FrontendAttrs", 7, ".moby.buildkit.v1.SolveRequest.FrontendAttrsEntry"),
					ref("Exporters", 13, ".moby.buildkit.v1.Exporter"),
					scalar("EnableSessionExporter", 14, boolean),
				},
				NestedType: []*descriptorpb.DescriptorProto{entry("ExporterAttrsDeprecatedEntry"), entry("FrontendAttrsEntry")},
			},
		},
	}
	fd, err := protodesc.NewFile(file, nil)
	if err != nil {
		t.Fatal(err)
	}
	return fd.Messages().ByName("SolveRequest")
}

type exporter struct {
	Type  string
	Attrs map[string]string
}

type solveRequest struct {
	Ref, Legacy, Session, Frontend string
	LegacyAttrs, FrontendAttrs     map[string]string
	Exporters                      []exporter
	SessionExporter                bool
}

func setMap(m protoreflect.Map, kv map[string]string) {
	for k, v := range kv {
		m.Set(protoreflect.ValueOfString(k).MapKey(), protoreflect.ValueOfString(v))
	}
}

func readMap(m protoreflect.Map) map[string]string {
	if m.Len() == 0 {
		return nil
	}
	out := map[string]string{}
	m.Range(func(k protoreflect.MapKey, v protoreflect.Value) bool {
		out[k.String()] = v.String()
		return true
	})
	return out
}

func encodeSolve(t *testing.T, desc protoreflect.MessageDescriptor, r solveRequest) []byte {
	t.Helper()
	f := desc.Fields().ByName
	m := dynamicpb.NewMessage(desc)
	for name, v := range map[protoreflect.Name]string{"Ref": r.Ref, "ExporterDeprecated": r.Legacy, "Session": r.Session, "Frontend": r.Frontend} {
		if v != "" {
			m.Set(f(name), protoreflect.ValueOfString(v))
		}
	}
	setMap(m.Mutable(f("ExporterAttrsDeprecated")).Map(), r.LegacyAttrs)
	setMap(m.Mutable(f("FrontendAttrs")).Map(), r.FrontendAttrs)
	list := m.Mutable(f("Exporters")).List()
	for _, e := range r.Exporters {
		el := list.NewElement()
		el.Message().Set(el.Message().Descriptor().Fields().ByName("Type"), protoreflect.ValueOfString(e.Type))
		setMap(el.Message().Mutable(el.Message().Descriptor().Fields().ByName("Attrs")).Map(), e.Attrs)
		list.Append(el)
	}
	if r.SessionExporter {
		m.Set(f("EnableSessionExporter"), protoreflect.ValueOfBool(true))
	}
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func decodeSolve(t *testing.T, desc protoreflect.MessageDescriptor, b []byte) solveRequest {
	t.Helper()
	m := dynamicpb.NewMessage(desc)
	if err := proto.Unmarshal(b, m); err != nil {
		t.Fatalf("rewritten SolveRequest does not parse: %v", err)
	}
	f := desc.Fields().ByName
	r := solveRequest{
		Ref: m.Get(f("Ref")).String(), Legacy: m.Get(f("ExporterDeprecated")).String(), Session: m.Get(f("Session")).String(), Frontend: m.Get(f("Frontend")).String(),
		LegacyAttrs: readMap(m.Get(f("ExporterAttrsDeprecated")).Map()), FrontendAttrs: readMap(m.Get(f("FrontendAttrs")).Map()),
		SessionExporter: m.Get(f("EnableSessionExporter")).Bool(),
	}
	list := m.Get(f("Exporters")).List()
	for i := range list.Len() {
		e := list.Get(i).Message()
		r.Exporters = append(r.Exporters, exporter{e.Get(e.Descriptor().Fields().ByName("Type")).String(), readMap(e.Get(e.Descriptor().Fields().ByName("Attrs")).Map())})
	}
	return r
}

func imageAttrs(extra map[string]string) map[string]string {
	out := map[string]string{"unpack": "true", "name-canonical": "true", "dangling-name-prefix": "docker.io/library/micropod-dangling", "danging-name-empty-only": "true"}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

func equalJSON(t *testing.T, label string, got, want any) {
	t.Helper()
	g, _ := json.Marshal(got)
	w, _ := json.Marshal(want)
	if !bytes.Equal(g, w) {
		t.Fatalf("%s:\n got  %s\n want %s", label, g, w)
	}
}

func TestSolveRewriteMapsMobyToImage(t *testing.T) {
	desc := controlDescriptors(t)
	frontend := map[string]string{"attest:provenance": "mode=min,inline-only=true", "filename": "Dockerfile", "image-resolve-mode": "local", "build-arg:RUN_ID": "one"}
	for _, tc := range []struct {
		name     string
		in, want solveRequest
	}{
		{
			// What buildx 0.38.1's docker driver sends for `docker build -t s3probe:rw -t docker.io/foo/bar .`
			name: "legacy and Exporters both moby",
			in: solveRequest{Ref: "r1", Session: "s1", Frontend: "dockerfile.v0", FrontendAttrs: frontend, SessionExporter: true,
				Legacy: "moby", LegacyAttrs: map[string]string{"name": "s3probe:rw,docker.io/foo/bar", "prefer-image-digest": "true"},
				Exporters: []exporter{{"moby", map[string]string{"name": "s3probe:rw,docker.io/foo/bar", "prefer-image-digest": "true"}}}},
			want: solveRequest{Ref: "r1", Session: "s1", Frontend: "dockerfile.v0", FrontendAttrs: frontend, SessionExporter: true,
				Legacy: "image", LegacyAttrs: imageAttrs(map[string]string{"name": "docker.io/library/s3probe:rw,docker.io/foo/bar:latest", "prefer-image-digest": "true"}),
				Exporters: []exporter{{"image", imageAttrs(map[string]string{"name": "docker.io/library/s3probe:rw,docker.io/foo/bar:latest", "prefer-image-digest": "true"})}}},
		},
		{
			// --push: push survives, buildx's unpack=false does not.
			name: "push keeps push and forces unpack",
			in: solveRequest{Legacy: "moby", LegacyAttrs: map[string]string{"name": "127.0.0.1:18620/s3/push:1", "push": "true", "unpack": "false", "prefer-image-digest": "true"},
				Exporters: []exporter{{"moby", map[string]string{"name": "127.0.0.1:18620/s3/push:1", "push": "true", "unpack": "false", "prefer-image-digest": "true"}}}},
			want: solveRequest{Legacy: "image", LegacyAttrs: imageAttrs(map[string]string{"name": "127.0.0.1:18620/s3/push:1", "push": "true", "prefer-image-digest": "true"}),
				Exporters: []exporter{{"image", imageAttrs(map[string]string{"name": "127.0.0.1:18620/s3/push:1", "push": "true", "prefer-image-digest": "true"})}}},
		},
		{
			// An untagged build: no name, so the dangling record names it.
			name: "untagged build",
			in:   solveRequest{Exporters: []exporter{{"moby", map[string]string{"prefer-image-digest": "true"}}}},
			want: solveRequest{Exporters: []exporter{{"image", imageAttrs(map[string]string{"prefer-image-digest": "true"})}}},
		},
		{
			// Only Exporters[] (newer clients); other exporters stay as they are.
			name: "local exporter beside moby",
			in:   solveRequest{Exporters: []exporter{{"local", map[string]string{"dest": "/out"}}, {"moby", map[string]string{"name": "Busybox"}}}},
			want: solveRequest{Exporters: []exporter{{"local", map[string]string{"dest": "/out"}}, {"image", imageAttrs(map[string]string{"name": "Busybox"})}}},
		},
		{
			// Our own keys win over anything a client sends.
			name: "client values for engine keys are replaced",
			in:   solveRequest{Legacy: "moby", LegacyAttrs: map[string]string{"name": "x", "name-canonical": "false", "dangling-name-prefix": "evil", "danging-name-empty-only": "false"}},
			want: solveRequest{Legacy: "image", LegacyAttrs: imageAttrs(map[string]string{"name": "docker.io/library/x:latest"})},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := decodeSolve(t, desc, rewriteSolveRequest(encodeSolve(t, desc, tc.in)))
			equalJSON(t, "rewritten request", got, tc.want)
		})
	}
}

func TestSolveRewriteLeavesOtherRequestsByteIdentical(t *testing.T) {
	desc := controlDescriptors(t)
	for name, in := range map[string]solveRequest{
		"empty probe solve": {},
		"image exporter":    {Exporters: []exporter{{"image", map[string]string{"name": "docker.io/library/a:1", "push": "true"}}}},
		"local exporter":    {Legacy: "local", LegacyAttrs: map[string]string{"dest": "/out"}, Exporters: []exporter{{"local", map[string]string{"dest": "/out"}}}},
		"oci tarball":       {Ref: "r", Session: "s", FrontendAttrs: map[string]string{"filename": "Dockerfile"}, Exporters: []exporter{{"oci", map[string]string{"dest": "out.tar"}}}},
	} {
		b := encodeSolve(t, desc, in)
		if got := rewriteSolveRequest(b); !bytes.Equal(got, b) {
			t.Fatalf("%s: rewritten\n got  %x\n want %x", name, got, b)
		}
	}
	for _, junk := range [][]byte{{0xff}, {0x1a, 0x05, 'm'}, protowire.AppendTag(nil, 13, protowire.BytesType)} {
		if got := rewriteSolveRequest(junk); !bytes.Equal(got, junk) {
			t.Fatalf("malformed %x rewritten to %x", junk, got)
		}
	}
	// A malformed Exporters entry is left exactly as received, the rest still rewritten.
	broken := protowire.AppendTag(nil, 13, protowire.BytesType)
	broken = protowire.AppendBytes(broken, []byte{0x0a, 0x04, 'm', 'o', 'b', 'y', 0x12, 0x09, 0xff})
	if got := rewriteSolveRequest(broken); !bytes.Equal(got, broken) {
		t.Fatalf("malformed exporter rewritten to %x", got)
	}
}

func TestNormalizeImageNames(t *testing.T) {
	for in, want := range map[string]string{
		"busybox":                             "docker.io/library/busybox:latest",
		"s3probe:rw":                          "docker.io/library/s3probe:rw",
		"me/app:1, ghcr.io/o/r":               "docker.io/me/app:1,ghcr.io/o/r:latest",
		"localhost:5000/x@sha256:" + hex64():  "localhost:5000/x@sha256:" + hex64(),
		"UPPER:case":                          "UPPER:case", // invalid: buildkit reports it
		",,":                                  "",
		"docker.io/library/micropod-dangling": "docker.io/library/micropod-dangling:latest",
	} {
		if got := normalizeImageNames(in); got != want {
			t.Errorf("normalizeImageNames(%q) = %q, want %q", in, got, want)
		}
	}
}

func hex64() string { return strings.Repeat("ab", 32) }

// fakeBuildkit is an upstream gRPC server that answers like buildkitd's Control
// service for the methods the proxy treats specially, and echoes otherwise.
type fakeBuildkit struct {
	mu    sync.Mutex
	calls map[string]metadata.MD
	solve []byte
}

func (f *fakeBuildkit) handle(_ any, ss grpc.ServerStream) error {
	method, _ := grpc.MethodFromServerStream(ss)
	md, _ := metadata.FromIncomingContext(ss.Context())
	f.mu.Lock()
	f.calls[method] = md
	f.mu.Unlock()
	switch method {
	case solveMethod:
		var b []byte
		if err := ss.RecvMsg(&b); err != nil {
			return err
		}
		f.mu.Lock()
		f.solve = b
		f.mu.Unlock()
		_ = ss.SetHeader(metadata.Pairs("x-up-header", "h1"))
		ss.SetTrailer(metadata.Pairs("x-up-trailer", "t1"))
		resp := appendString(nil, 1, "solved")
		return ss.SendMsg(&resp)
	case "/test.Echo/Fail":
		return status.Error(codes.NotFound, "nope")
	case sessionMethod:
		for {
			var b []byte
			if err := ss.RecvMsg(&b); errors.Is(err, io.EOF) {
				return nil
			} else if err != nil {
				return err
			}
			data, _ := bytesField(b, 1)
			out := protowire.AppendTag(nil, 1, protowire.BytesType)
			out = protowire.AppendBytes(out, bytes.ToUpper(data))
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
	up   *fakeBuildkit
	sock string
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
	upstream := grpc.NewServer(grpc.UnknownServiceHandler(h.up.handle), grpc.ForceServerCodec(rawCodec{}))
	go upstream.Serve(ul)
	t.Cleanup(upstream.Stop)
	cc, err := grpc.NewClient("unix://"+upSock, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cc.Close() })
	conns := func(context.Context) (*grpc.ClientConn, error) { return cc, nil }
	proxy := newBuildkitProxy(conns)
	pl, err := net.Listen("unix", h.sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{ReadTimeout: 30 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := buildkitUpgrade(w, r, strings.TrimPrefix(r.URL.Path, "/"), conns, proxy); err != nil {
			var problem apiError
			if errors.As(err, &problem) {
				http.Error(w, problem.message, problem.code)
				return
			}
			http.Error(w, err.Error(), 500)
		}
	})}
	go srv.Serve(pl)
	t.Cleanup(func() { srv.Close() })
	return h
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
	return bufferedConn{conn, br}, resp
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
	desc := controlDescriptors(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ctx = metadata.AppendToOutgoingContext(ctx, "x-client-md", "v1")

	req := encodeSolve(t, desc, solveRequest{Ref: "r1", Legacy: "moby", LegacyAttrs: map[string]string{"name": "app:1"},
		Exporters: []exporter{{"moby", map[string]string{"name": "app:1"}}}})
	var resp []byte
	var header, trailer metadata.MD
	if err := cc.Invoke(ctx, solveMethod, &req, &resp, grpc.ForceCodec(rawCodec{}), grpc.Header(&header), grpc.Trailer(&trailer)); err != nil {
		t.Fatal(err)
	}
	if want := appendString(nil, 1, "solved"); !bytes.Equal(resp, want) {
		t.Fatalf("Solve response %x, want %x", resp, want)
	}
	if header.Get("x-up-header")[0] != "h1" || trailer.Get("x-up-trailer")[0] != "t1" {
		t.Fatalf("upstream header %v / trailer %v not forwarded", header, trailer)
	}
	h.up.mu.Lock()
	got := decodeSolve(t, desc, h.up.solve)
	md := h.up.calls[solveMethod]
	h.up.mu.Unlock()
	if got.Legacy != "image" || got.Exporters[0].Type != "image" || got.Exporters[0].Attrs["name"] != "docker.io/library/app:1" || got.LegacyAttrs["unpack"] != "true" {
		t.Fatalf("upstream received %+v", got)
	}
	if v := md.Get("x-client-md"); len(v) != 1 || v[0] != "v1" {
		t.Fatalf("client metadata not forwarded: %v", md)
	}

	// Any other service passes through byte for byte, as a bidirectional stream.
	stream, err := cc.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, "/moby.buildkit.v1.frontend.LLBBridge/Ping", grpc.ForceCodec(rawCodec{}))
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
	err = cc.Invoke(ctx, "/test.Echo/Fail", &req, &resp, grpc.ForceCodec(rawCodec{}))
	if st, _ := status.FromError(err); st.Code() != codes.NotFound || st.Message() != "nope" {
		t.Fatalf("upstream error became %v", err)
	}
}

func TestSessionBridge(t *testing.T) {
	h := newProxyHarness(t)
	conn, resp := h.upgrade(t, "/session", http.Header{
		"X-Docker-Expose-Session-Uuid":        {"u1"},
		"X-Docker-Expose-Session-Sharedkey":   {"k1"},
		"X-Docker-Expose-Session-Grpc-Method": {"/moby.filesync.v1.FileSync/DiffCopy", "/grpc.health.v1.Health/Check"},
		"X-Unrelated":                         {"no"},
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
	md := h.up.calls[sessionMethod]
	h.up.mu.Unlock()
	if md.Get("x-docker-expose-session-uuid")[0] != "u1" || md.Get("x-docker-expose-session-sharedkey")[0] != "k1" ||
		!slices.Equal(md.Get("x-docker-expose-session-grpc-method"), []string{"/moby.filesync.v1.FileSync/DiffCopy", "/grpc.health.v1.Health/Check"}) ||
		len(md.Get("x-unrelated")) != 0 {
		t.Fatalf("session metadata %v", md)
	}
	// The client's half-close ends the upstream session, which closes the connection.
	if err := conn.(bufferedConn).Conn.(*net.UnixConn).CloseWrite(); err != nil {
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

func TestBuildkitRoutesWithoutBuildkitd(t *testing.T) {
	if buildkitAvailable() {
		t.Skip("this host has the bundled buildkitd")
	}
	for _, path := range []string{"grpc", "session"} {
		handled, err := buildkitRoutes(nil, httptest.NewRecorder(), httptest.NewRequest("POST", "/"+path, nil), "POST", path)
		var problem apiError
		if !handled || !errors.As(err, &problem) || problem.code != 503 || !strings.Contains(problem.message, "lacks buildkitd") {
			t.Fatalf("%s: handled=%v err=%v", path, handled, err)
		}
	}
	if handled, err := buildkitRoutes(nil, nil, nil, "GET", "grpc"); handled || err != nil {
		t.Fatalf("GET /grpc claimed: %v %v", handled, err)
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

	rec := call("/_ping")
	if want := map[bool]string{true: "2", false: ""}[buildkitAvailable()]; rec.Header().Get("Builder-Version") != want {
		t.Fatalf("Builder-Version %q, want %q", rec.Header().Get("Builder-Version"), want)
	}
	var version struct {
		GitCommit            string
		MicropodCapabilities []string
	}
	if err := json.Unmarshal(call("/version").Body.Bytes(), &version); err != nil {
		t.Fatal(err)
	}
	if version.GitCommit != engineCommit || !slices.Equal(version.MicropodCapabilities, engineCapabilities(buildkitAvailable())) {
		t.Fatalf("version %+v", version)
	}
	if !slices.Equal(engineCapabilities(true), []string{"caches", "buildkit", "grpc-build"}) || !slices.Equal(engineCapabilities(false), []string{"caches"}) {
		t.Fatal("capability lists changed")
	}
}

// fakeImages answers the two CRI image calls the digest resolver makes.
type fakeImages struct {
	cri.ImageServiceClient
	known  map[string]string // ImageStatus ref -> ID
	images []*cri.Image
	lists  int
}

func (f *fakeImages) ImageStatus(_ context.Context, r *cri.ImageStatusRequest, _ ...grpc.CallOption) (*cri.ImageStatusResponse, error) {
	if id, ok := f.known[r.GetImage().GetImage()]; ok {
		return &cri.ImageStatusResponse{Image: &cri.Image{Id: id}}, nil
	}
	return &cri.ImageStatusResponse{}, nil
}

func (f *fakeImages) ListImages(context.Context, *cri.ListImagesRequest, ...grpc.CallOption) (*cri.ListImagesResponse, error) {
	f.lists++
	return &cri.ListImagesResponse{Images: f.images}, nil
}

func TestResolveImageDigest(t *testing.T) {
	cfg := "sha256:" + strings.Repeat("c", 64)
	index := "sha256:" + strings.Repeat("1", 64)
	dangling := "sha256:" + strings.Repeat("2", 64)
	images := &fakeImages{known: map[string]string{cfg: cfg}, images: []*cri.Image{
		{Id: "sha256:" + strings.Repeat("9", 64), RepoDigests: []string{"docker.io/library/other@sha256:" + strings.Repeat("3", 64)}},
		{Id: cfg, RepoTags: []string{"docker.io/library/s3e:2"}, RepoDigests: []string{"docker.io/library/s3e@" + index}},
		{Id: "sha256:" + strings.Repeat("d", 64), RepoDigests: []string{"docker.io/library/micropod-dangling@" + dangling}},
	}}
	s := &dockerEngine{node: node{images: images}}
	ctx := context.Background()
	for in, want := range map[string]string{
		"alpine:3.20":                       "alpine:3.20",
		"docker.io/library/s3e@" + index:    "docker.io/library/s3e@" + index,
		"sha256:" + strings.Repeat("c", 12): "sha256:" + strings.Repeat("c", 12), // short IDs go to CRI as typed
		cfg:                                 cfg,
		index:                               cfg,
		dangling:                            "sha256:" + strings.Repeat("d", 64),
		"sha256:" + strings.Repeat("4", 64): "sha256:" + strings.Repeat("4", 64), // unknown: create reports it
	} {
		if got := s.resolveImageDigest(ctx, in); got != want {
			t.Errorf("resolveImageDigest(%q) = %q, want %q", in, got, want)
		}
	}
	if images.lists != 3 {
		t.Fatalf("ListImages ran %d times, want only for the 3 digests CRI did not know", images.lists)
	}
}
