package main

// Stock `docker build` on the Docker socket. Docker CLI 29 hands every build to
// buildx, whose default "docker" driver probes POST /grpc for an h2c upgrade and
// then talks BuildKit's gRPC API over it, with client sessions (build context,
// auth, secrets, SSH) over POST /session. This file serves both the way dockerd
// does, backed by the bundled buildkitd:
//
//   - /grpc forwards every gRPC method byte for byte (Control, frontend
//     LLBBridge, containerd Content, OpenTelemetry trace export). Only
//     Control/Solve is rewritten: the docker driver asks for dockerd's "moby"
//     exporter, which standalone buildkitd lacks; it becomes the "image"
//     exporter with unpack=true, so the result is a containerd image in the
//     k8s.io namespace that CRI (and so `docker run`) sees at once.
//   - /session bridges the hijacked connection into Control/Session, the
//     stream that dockerd's session manager would otherwise terminate.
//
// Wire handling uses protowire on the few SolveRequest fields involved instead
// of importing github.com/moby/buildkit, whose dependency graph would raise this
// module's go directive, gRPC and cri-api.

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/distribution/reference"
	"golang.org/x/net/http2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/encoding/protowire"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func init() {
	extraRoutes = append(extraRoutes, buildkitRoutes)
}

// One proxy server for every /grpc connection; it holds no per-connection state.
var buildkitGRPC = newBuildkitProxy(sharedBuildkit.clientConn)

func buildkitRoutes(s *dockerEngine, w http.ResponseWriter, r *http.Request, method, path string) (bool, error) {
	if method != "POST" || (path != "grpc" && path != "session") {
		return false, nil
	}
	if !buildkitAvailable() {
		return true, errBuildkitUnavailable
	}
	return true, buildkitUpgrade(w, r, path, sharedBuildkit.clientConn, buildkitGRPC)
}

const (
	solveMethod   = "/moby.buildkit.v1.Control/Solve"
	sessionMethod = "/moby.buildkit.v1.Control/Session"
	// Untagged builds get a <prefix>@<digest> image record so their ID resolves.
	danglingImagePrefix = "docker.io/library/micropod-dangling"
)

type clientConnFunc func(context.Context) (*grpc.ClientConn, error)

// buildkitUpgrade answers an HTTP/1.1 h2c upgrade on the Docker socket. The
// dispatcher already holds an engineLease, which therefore lasts as long as the
// hijacked connection.
func buildkitUpgrade(w http.ResponseWriter, r *http.Request, path string, clientConn clientConnFunc, proxy *grpc.Server) error {
	if !strings.EqualFold(r.Header.Get("Upgrade"), "h2c") {
		return fail(400, "expected Upgrade: h2c")
	}
	cc, err := clientConn(r.Context())
	if err != nil {
		return err
	}
	conn, err := upgradeH2C(w)
	if err != nil {
		return nil // the connection is gone or already answered
	}
	defer conn.Close()
	if path == "grpc" {
		serveBuildkitGRPC(r.Context(), conn, proxy)
		return nil
	}
	if err := bridgeSession(r.Context(), cc, sessionMetadata(r.Header), conn); err != nil {
		fmt.Fprintln(os.Stderr, "BuildKit session:", err)
	}
	return nil
}

// bufferedConn keeps bytes the client pipelined behind its upgrade request.
type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// upgradeH2C hijacks the request and confirms the protocol switch. net/http
// clears the server's read and write deadlines when it hands over the conn.
func upgradeH2C(w http.ResponseWriter) (net.Conn, error) {
	conn, rw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(conn, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n"); err != nil {
		conn.Close()
		return nil, err
	}
	return bufferedConn{conn, rw.Reader}, nil
}

func serveBuildkitGRPC(ctx context.Context, conn net.Conn, srv *grpc.Server) {
	(&http2.Server{}).ServeConn(conn, &http2.ServeConnOpts{Context: ctx, Handler: srv})
}

// rawCodec moves gRPC messages as opaque bytes. Its name is "proto" so both
// ends keep the content-subtype the real messages use.
type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error) { return *(v.(*[]byte)), nil }
func (rawCodec) Unmarshal(b []byte, v any) error {
	*(v.(*[]byte)) = append([]byte(nil), b...) // gRPC may reuse b
	return nil
}
func (rawCodec) Name() string { return "proto" }

// newBuildkitProxy is a gRPC server with no registered services: every method
// reaches forwardStream, which replays it on the upstream connection.
func newBuildkitProxy(upstream clientConnFunc) *grpc.Server {
	return grpc.NewServer(
		grpc.UnknownServiceHandler(func(_ any, ss grpc.ServerStream) error { return forwardStream(ss, upstream) }),
		grpc.ForceServerCodec(rawCodec{}),
		grpc.MaxRecvMsgSize(buildkitMaxMessage), grpc.MaxSendMsgSize(buildkitMaxMessage))
}

// Transport-level keys the client stack sets again for the upstream call.
func forwardedMetadata(md metadata.MD) metadata.MD {
	out := metadata.MD{}
	for k, v := range md {
		if strings.HasPrefix(k, ":") || k == "content-type" || k == "user-agent" || k == "te" || strings.HasPrefix(k, "grpc-") {
			continue
		}
		out[k] = v
	}
	return out
}

// forwardStream pumps one call in both directions. Every method is treated as a
// bidirectional stream, which covers unary and server-streaming calls as well.
// The deadline and cancellation follow the incoming call's context.
func forwardStream(ss grpc.ServerStream, upstream clientConnFunc) error {
	method, ok := grpc.MethodFromServerStream(ss)
	if !ok {
		return fmt.Errorf("unknown gRPC method")
	}
	cc, err := upstream(ss.Context())
	if err != nil {
		return err
	}
	md, _ := metadata.FromIncomingContext(ss.Context())
	ctx, cancel := context.WithCancel(metadata.NewOutgoingContext(ss.Context(), forwardedMetadata(md)))
	defer cancel()
	cs, err := cc.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true, ClientStreams: true}, method, grpc.ForceCodec(rawCodec{}))
	if err != nil {
		return err
	}
	go func() {
		for {
			var b []byte
			if err := ss.RecvMsg(&b); err != nil {
				// io.EOF is the client's half-close; anything else ends ctx too.
				_ = cs.CloseSend()
				return
			}
			if method == solveMethod {
				b = rewriteSolveRequest(b)
			}
			if err := cs.SendMsg(&b); err != nil {
				return // RecvMsg below reports the upstream status
			}
		}
	}()
	if h, err := cs.Header(); err == nil && len(h) > 0 {
		_ = ss.SendHeader(h)
	}
	for {
		var b []byte
		if err := cs.RecvMsg(&b); err != nil {
			ss.SetTrailer(cs.Trailer())
			if err == io.EOF {
				return nil
			}
			return err // an upstream status passes through unchanged
		}
		if err := ss.SendMsg(&b); err != nil {
			return err
		}
	}
}

// sessionMetadata carries the session identity buildx sends as HTTP headers
// (uuid, name, shared key, exposed gRPC methods) as lower-cased gRPC metadata,
// which is what BuildKit's grpchijack dialer sends to Control/Session.
func sessionMetadata(h http.Header) metadata.MD {
	md := metadata.MD{}
	for k, v := range h {
		if lk := strings.ToLower(k); strings.HasPrefix(lk, "x-docker-expose-session-") || strings.HasPrefix(lk, "x-buildkit-session-") {
			md[lk] = append(md[lk], v...)
		}
	}
	return md
}

// bridgeSession tunnels the client's HTTP/2 session connection through a
// Control/Session stream: each direction's bytes travel as BytesMessage{data=1}.
func bridgeSession(ctx context.Context, cc *grpc.ClientConn, md metadata.MD, conn net.Conn) error {
	ctx, cancel := context.WithCancel(metadata.NewOutgoingContext(ctx, md))
	defer cancel()
	cs, err := cc.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true, ClientStreams: true}, sessionMethod, grpc.ForceCodec(rawCodec{}))
	if err != nil {
		return err
	}
	go func() {
		// On the client's EOF only the upstream send side closes, so bytes
		// buildkitd still has in flight reach the client; buildkitd then ends
		// the stream. If the stream ends first, the caller closes conn.
		buf := make([]byte, 32<<10)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				msg := protowire.AppendTag(nil, 1, protowire.BytesType)
				msg = protowire.AppendBytes(msg, buf[:n])
				if cs.SendMsg(&msg) != nil {
					return
				}
			}
			if err != nil {
				_ = cs.CloseSend()
				return
			}
		}
	}()
	for {
		var b []byte
		if err := cs.RecvMsg(&b); err != nil {
			if err == io.EOF || ctx.Err() != nil {
				return nil
			}
			return err
		}
		data, ok := bytesField(b, 1)
		if !ok {
			return fmt.Errorf("malformed session frame")
		}
		if len(data) > 0 {
			if _, err := conn.Write(data); err != nil {
				return nil
			}
		}
	}
}

// field is one top-level protobuf field: raw is the tag and value as received,
// val the payload of a length-delimited field.
type field struct {
	num protowire.Number
	typ protowire.Type
	raw []byte
	val []byte
}

func parseFields(b []byte) ([]field, bool) {
	var out []field
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return nil, false
		}
		m := protowire.ConsumeFieldValue(num, typ, b[n:])
		if m < 0 {
			return nil, false
		}
		f := field{num: num, typ: typ, raw: b[:n+m]}
		if typ == protowire.BytesType {
			f.val, _ = protowire.ConsumeBytes(b[n:])
		}
		out = append(out, f)
		b = b[n+m:]
	}
	return out, true
}

// bytesField returns the last occurrence of a length-delimited field (the
// protobuf rule for a repeated scalar field); an absent field reads as empty.
func bytesField(b []byte, num protowire.Number) ([]byte, bool) {
	fs, ok := parseFields(b)
	if !ok {
		return nil, false
	}
	var v []byte
	for _, f := range fs {
		if f.num == num && f.typ == protowire.BytesType {
			v = f.val
		}
	}
	return v, true
}

type attr struct{ key, value string }

func mapEntry(b []byte) (attr, bool) {
	fs, ok := parseFields(b)
	if !ok {
		return attr{}, false
	}
	var a attr
	for _, f := range fs {
		switch {
		case f.num == 1 && f.typ == protowire.BytesType:
			a.key = string(f.val)
		case f.num == 2 && f.typ == protowire.BytesType:
			a.value = string(f.val)
		}
	}
	return a, true
}

func appendString(b []byte, num protowire.Number, s string) []byte {
	b = protowire.AppendTag(b, num, protowire.BytesType)
	return protowire.AppendString(b, s)
}

func appendAttrs(b []byte, num protowire.Number, attrs []attr) []byte {
	for _, a := range attrs {
		e := appendString(nil, 1, a.key)
		e = appendString(e, 2, a.value)
		b = protowire.AppendTag(b, num, protowire.BytesType)
		b = protowire.AppendBytes(b, e)
	}
	return b
}

// normalizeImageNames gives each comma-separated name its canonical form
// (busybox -> docker.io/library/busybox:latest). CRI looks images up by that
// form only; a short name would make `docker run <tag>` try to pull.
func normalizeImageNames(v string) string {
	var names []string
	for _, n := range strings.Split(v, ",") {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		if r, err := reference.ParseNormalizedNamed(n); err == nil {
			n = reference.TagNameOnly(r).String()
		}
		names = append(names, n)
	}
	return strings.Join(names, ",")
}

// imageExporterAttrs turns the docker driver's moby exporter attributes into
// the image exporter's. push, prefer-image-digest and anything else pass
// through; unpack is always true (buildx sends unpack=false with --push).
// name-canonical adds a <name>@<digest> record and untagged builds get a
// dangling one, so the manifest digest buildx reports for --iidfile and -q
// resolves to an image. "danging" is BuildKit's own spelling of the key.
func imageExporterAttrs(in []attr) []attr {
	set := []attr{{"unpack", "true"}, {"name-canonical", "true"}, {"dangling-name-prefix", danglingImagePrefix}, {"danging-name-empty-only", "true"}}
	out := make([]attr, 0, len(in)+len(set))
	for _, a := range in {
		switch a.key {
		case "unpack", "name-canonical", "dangling-name-prefix", "danging-name-empty-only":
			continue
		case "name":
			a.value = normalizeImageNames(a.value)
		}
		out = append(out, a)
	}
	return append(out, set...)
}

// rewriteExporter rewrites one Exporter message {1: Type, 2: Attrs} when its
// type is moby and returns any other exporter unchanged.
func rewriteExporter(b []byte) []byte {
	fs, ok := parseFields(b)
	if !ok {
		return b
	}
	var typ string
	var attrs []attr
	var rest []byte
	for _, f := range fs {
		switch {
		case f.num == 1 && f.typ == protowire.BytesType:
			typ = string(f.val)
		case f.num == 2 && f.typ == protowire.BytesType:
			a, ok := mapEntry(f.val)
			if !ok {
				return b
			}
			attrs = append(attrs, a)
		default:
			rest = append(rest, f.raw...)
		}
	}
	if typ != "moby" {
		return b
	}
	out := appendString(nil, 1, "image")
	out = appendAttrs(out, 2, imageExporterAttrs(attrs))
	return append(out, rest...)
}

// rewriteSolveRequest maps the moby exporter to the image exporter in a
// SolveRequest's legacy fields (3 ExporterDeprecated, 4 ExporterAttrsDeprecated)
// and in each Exporters entry (13). buildx 0.38 fills both. A request without a
// moby exporter, or one that does not parse, is returned byte for byte.
func rewriteSolveRequest(b []byte) []byte {
	fs, ok := parseFields(b)
	if !ok {
		return b
	}
	var legacy string
	var legacyAttrs []attr
	moby := false
	for _, f := range fs {
		switch {
		case f.num == 3 && f.typ == protowire.BytesType:
			legacy = string(f.val)
		case f.num == 4 && f.typ == protowire.BytesType:
			a, ok := mapEntry(f.val)
			if !ok {
				return b
			}
			legacyAttrs = append(legacyAttrs, a)
		case f.num == 13 && f.typ == protowire.BytesType:
			if typ, ok := bytesField(f.val, 1); ok && string(typ) == "moby" {
				moby = true
			}
		}
	}
	if legacy == "moby" {
		moby = true
	}
	if !moby {
		return b
	}
	out := make([]byte, 0, len(b)+256)
	for _, f := range fs {
		switch {
		case legacy == "moby" && (f.num == 3 || f.num == 4) && f.typ == protowire.BytesType:
			continue // re-added below
		case f.num == 13 && f.typ == protowire.BytesType:
			out = protowire.AppendTag(out, 13, protowire.BytesType)
			out = protowire.AppendBytes(out, rewriteExporter(f.val))
		default:
			out = append(out, f.raw...)
		}
	}
	if legacy == "moby" {
		out = appendString(out, 3, "image")
		out = appendAttrs(out, 4, imageExporterAttrs(legacyAttrs))
	}
	return out
}

var bareDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// resolveImageDigest maps a bare manifest or index digest to the image ID.
// buildx's docker driver reports that digest (for --iidfile and `build -q`)
// instead of the config digest CRI uses as the ID; the image exporter's
// <name>@<digest> record carries it as a repo digest. Anything else, and a
// digest CRI already knows, is returned unchanged.
func (s *dockerEngine) resolveImageDigest(ctx context.Context, image string) string {
	if !bareDigest.MatchString(image) {
		return image
	}
	if st, err := s.node.images.ImageStatus(ctx, &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: image}}); err == nil && st.GetImage().GetId() != "" {
		return image
	}
	list, err := s.node.images.ListImages(ctx, &cri.ListImagesRequest{})
	if err != nil {
		return image
	}
	for _, img := range list.GetImages() {
		for _, d := range img.GetRepoDigests() {
			if strings.HasSuffix(d, "@"+image) {
				// The ID, not the repo digest: CRI ImageStatus refuses name:tag@digest.
				return img.GetId()
			}
		}
	}
	return image
}
