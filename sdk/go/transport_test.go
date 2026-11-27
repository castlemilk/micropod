package micropod_test

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"connectrpc.com/connect"
	micropod "github.com/castlemilk/micropod/sdk/go"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
)

// pingServer answers Ping and records the protocol and content type of
// every request it saw.
type pingServer struct {
	micropodv1connect.UnimplementedSystemServiceHandler
	seen chan [2]string
}

func (p *pingServer) Ping(_ context.Context, req *connect.Request[micropodv1.Empty]) (*connect.Response[micropodv1.PingResponse], error) {
	return connect.NewResponse(&micropodv1.PingResponse{Status: "running"}), nil
}

func serve(t *testing.T, listener net.Listener) chan [2]string {
	t.Helper()
	seen := make(chan [2]string, 16)
	mux := http.NewServeMux()
	path, handler := micropodv1connect.NewSystemServiceHandler(&pingServer{})
	mux.Handle("/api"+path, http.StripPrefix("/api", handler))
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- [2]string{r.Proto, r.Header.Get("Content-Type")}
		mux.ServeHTTP(w, r)
	}))
	var protocols http.Protocols
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	server.Config.Protocols = &protocols
	server.Listener.Close()
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)
	return seen
}

func TestTheDefaultTransportStaysHTTP1(t *testing.T) {
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	seen := serve(t, listener)
	client := micropod.NewClient("http://" + listener.Addr().String() + "/api")
	if _, err := client.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{})); err != nil {
		t.Fatal(err)
	}
	if got := <-seen; got[0] != "HTTP/1.1" || got[1] != "application/proto" {
		t.Fatalf("default client: %v, want HTTP/1.1 Connect", got)
	}
}

func TestWithHTTP2AndWithGRPC(t *testing.T) {
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	seen := serve(t, listener)
	base := "http://" + listener.Addr().String() + "/api"
	h2 := micropod.NewClient(base, micropod.WithHTTP2())
	if _, err := h2.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{})); err != nil {
		t.Fatal(err)
	}
	if got := <-seen; got[0] != "HTTP/2.0" || got[1] != "application/proto" {
		t.Fatalf("WithHTTP2: %v, want HTTP/2.0 Connect", got)
	}
	grpc := micropod.NewClient(base, micropod.WithGRPC())
	resp, err := grpc.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if got := <-seen; got[0] != "HTTP/2.0" || got[1] != "application/grpc" {
		t.Fatalf("WithGRPC: %v, want HTTP/2.0 application/grpc", got)
	}
	if resp.Msg.GetStatus() != "running" {
		t.Fatalf("status %q", resp.Msg.GetStatus())
	}
}

func TestWithUnixSocket(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mp-sdk-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "api.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	seen := serve(t, listener)
	for _, opts := range [][]micropod.Option{{}, {micropod.WithHTTP2()}} {
		client := micropod.NewClient("http://localhost/api", append(opts, micropod.WithUnixSocket(path))...)
		if _, err := client.Ping(context.Background(), connect.NewRequest(&micropodv1.Empty{})); err != nil {
			t.Fatal(err)
		}
		<-seen
	}
}
