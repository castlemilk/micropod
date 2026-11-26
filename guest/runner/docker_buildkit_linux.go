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
func (s *dockerEngine) serveDockerBuildControl(ctx context.Context, conn net.Conn, bk control.ControlClient) {
	transport := &http2.Transport{AllowHTTP: true, DialTLSContext: func(ctx context.Context, _, _ string, _ *tls.Config) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", s.buildkitSocket)
	}}
	defer transport.CloseIdleConnections()
	proxy := httputil.ReverseProxy{Transport: transport, FlushInterval: -1, Rewrite: func(r *httputil.ProxyRequest) {
		r.Out.URL.Scheme, r.Out.URL.Host, r.Out.Host = "http", "localhost", "localhost"
	}}
	solver := grpc.NewServer(grpc.MaxRecvMsgSize(buildkitMaxMessage), grpc.MaxSendMsgSize(buildkitMaxMessage))
	control.RegisterControlServer(solver, dockerBuildSolver{backend: bk, node: s.node})
	defer solver.Stop()
	handler := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == control.Control_Solve_FullMethodName {
			solver.ServeHTTP(w, req)
			return
		}
		proxy.ServeHTTP(w, req)
	})
	server := &http2.Server{IdleTimeout: time.Minute}
	server.ServeConn(conn, &http2.ServeConnOpts{Context: ctx, Handler: handler})
}

type dockerBuildSolver struct {
	control.UnimplementedControlServer
	backend control.ControlClient
	node    node
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
