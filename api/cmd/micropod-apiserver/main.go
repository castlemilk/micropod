// Command micropod-apiserver serves the Micropod management API on
// 127.0.0.1:45454 and [::1]:45454. connect-go handlers speak the Connect protocol, gRPC and
// gRPC-Web on the same port.
//
// Environment: MICROPOD_API_PORT (default 45454), MICROPOD_CONTAINER_CLI_PATH.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/validate"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"micropod/api/internal/clicli"
	"micropod/api/internal/localguard"
	"micropod/api/internal/metrics"
	"micropod/api/internal/server"
)

func main() {
	port := os.Getenv("MICROPOD_API_PORT")
	if port == "" {
		port = "45454"
	}
	cli := clicli.New()
	if !cli.Available() {
		log.Fatalf("`container` CLI not found at %s", cli.Bin)
	}

	metricsReg := metrics.NewRegistry()
	mux := http.NewServeMux()
	// One connect-go handler per domain service; the Server implements all
	// six. buf.validate constraints in the protos are enforced by the
	// interceptor — an invalid request is rejected with invalid_argument
	// before reaching a handler.
	svc := server.New(cli)
	opts := []connect.HandlerOption{connect.WithInterceptors(validate.NewInterceptor())}
	mounts := []func(*server.Server, ...connect.HandlerOption) (string, http.Handler){
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewContainerServiceHandler(s, o...)
		},
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewImageServiceHandler(s, o...)
		},
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewVolumeServiceHandler(s, o...)
		},
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewNetworkServiceHandler(s, o...)
		},
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewComposeServiceHandler(s, o...)
		},
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewSystemServiceHandler(s, o...)
		},
		func(s *server.Server, o ...connect.HandlerOption) (string, http.Handler) {
			return micropodv1connect.NewK8SServiceHandler(s, o...)
		},
	}
	for _, mount := range mounts {
		pattern, handler := mount(svc, opts...)
		mux.Handle(pattern, handler)
	}
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"status":"ok"}`)
	})
	mux.Handle("/metrics", metricsReg)

	portNum, err := strconv.Atoi(port)
	if err != nil {
		log.Fatalf("bad MICROPOD_API_PORT %q: %v", port, err)
	}
	// Host / Content-Type / Origin admission before any handler: the API is
	// unauthenticated, so a web page must not be able to drive it with a
	// no-preflight cross-site request or through DNS rebinding.
	handler := localguard.Wrap(metricsReg.Wrap(mux), portNum)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	// Loopback only, both families: http://localhost:45454 (docs, SDKs)
	// works whichever address the client's resolver tries first. IPv6 may be
	// disabled on the host; IPv4 is required.
	v4, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("Micropod API listening on http://127.0.0.1:%s (cli: %s)", port, cli.Bin)
	if v6, err := net.Listen("tcp", "[::1]:"+port); err != nil {
		log.Printf("IPv6 loopback listener unavailable: %v", err)
	} else {
		log.Printf("Micropod API listening on http://[::1]:%s", port)
		go func() { log.Fatal(server.Serve(v6)) }()
	}
	log.Fatal(server.Serve(v4))
}
