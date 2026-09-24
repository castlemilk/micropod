// Command micropod-apiserver serves the Micropod management API on
// 127.0.0.1:45454. connect-go handlers speak the Connect protocol, gRPC and
// gRPC-Web on the same port.
//
// Environment: MICROPOD_API_PORT (default 45454), MICROPOD_CONTAINER_CLI_PATH.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/validate"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"micropod/api/internal/clicli"
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
	// buf.validate constraints in the protos are enforced here — an invalid
	// request is rejected with invalid_argument before reaching a handler.
	pattern, handler := micropodv1connect.NewMicropodServiceHandler(
		server.New(cli),
		connect.WithInterceptors(validate.NewInterceptor()),
	)
	mux.Handle(pattern, handler)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"status":"ok"}`)
	})
	mux.Handle("/metrics", metricsReg)

	addr := "127.0.0.1:" + port
	log.Printf("Micropod API listening on http://%s (cli: %s)", addr, cli.Bin)
	server := &http.Server{
		Addr:            addr,
		Handler:         metricsReg.Wrap(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
