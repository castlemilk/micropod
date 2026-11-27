//go:build interop

// Interop of the real grpc-go and connect-go clients with a running Swift
// MicropodAPI over HTTP/2 (h2c prior knowledge). Run by scripts/h2-interop.sh
// against a throwaway API:
//
//	MICROPOD_INTEROP_SOCK=/tmp/x/api.sock MICROPOD_INTEROP_TCP=127.0.0.1:20031 \
//	    go test -tags interop -run Interop -v .
//
// MICROPOD_INTEROP_CONTAINER names a running container that logs (the
// stream, not-found and cancel cases need a runtime behind the API), and
// MICROPOD_INTEROP_FLOOD_SECONDS runs the log-flood soak that sets the
// control-frame bound: grpc-go sends a BDP PING per data round trip.
package micropod_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	micropod "github.com/castlemilk/micropod/sdk/go"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
)

type interopTarget struct {
	name   string
	grpc   string // grpc.NewClient target
	base   string // connect-go base URL
	socket string
}

func interopTargets(t *testing.T) []interopTarget {
	t.Helper()
	var targets []interopTarget
	if path := os.Getenv("MICROPOD_INTEROP_SOCK"); path != "" {
		targets = append(targets, interopTarget{"unix", "unix://" + path, "http://localhost/api", path})
	}
	if addr := os.Getenv("MICROPOD_INTEROP_TCP"); addr != "" {
		targets = append(targets, interopTarget{"tcp", addr, "http://" + addr + "/api", ""})
	}
	if len(targets) == 0 {
		t.Skip("set MICROPOD_INTEROP_SOCK and/or MICROPOD_INTEROP_TCP")
	}
	return targets
}

func dial(t *testing.T, target interopTarget) *grpc.ClientConn {
	t.Helper()
	conn, err := grpc.NewClient(target.grpc, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func connectClient(target interopTarget, opts ...micropod.Option) *micropod.Client {
	if target.socket != "" {
		opts = append(opts, micropod.WithUnixSocket(target.socket))
	}
	return micropod.NewClient(target.base, opts...)
}

func TestInteropGRPCUnary(t *testing.T) {
	for _, target := range interopTargets(t) {
		t.Run(target.name, func(t *testing.T) {
			conn := dial(t, target)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			ping, err := micropodv1.NewSystemServiceClient(conn).Ping(ctx, &micropodv1.Empty{})
			if err != nil {
				t.Fatalf("Ping: %v", err)
			}
			t.Logf("Ping: %s/%s", ping.GetStatus(), ping.GetRuntimeBackend())

			err = conn.Invoke(ctx, "/micropod.v1.SystemService/Teleport", &micropodv1.Empty{}, &micropodv1.Empty{})
			if status.Code(err) != codes.Unimplemented {
				t.Fatalf("an unknown method: %v, want Unimplemented", err)
			}
			health, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{})
			if err != nil || health.GetStatus() != healthpb.HealthCheckResponse_SERVING {
				t.Fatalf("health Check: %v %v", health, err)
			}
			_, err = healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{Service: "nope"})
			if status.Code(err) != codes.NotFound {
				t.Fatalf("health Check of an unknown service: %v", err)
			}

			// A message far bigger than one frame or window.
			big := &micropodv1.ContainerRef{Id: strings.Repeat("a", 4<<20)}
			_, err = micropodv1.NewContainerServiceClient(conn).GetContainer(ctx, big)
			if code := status.Code(err); code == codes.Internal || code == codes.Unknown || code == codes.OK {
				t.Fatalf("a 4 MiB request: %v", err)
			}
			t.Logf("4 MiB GetContainer: %v", status.Code(err))

			if os.Getenv("MICROPOD_INTEROP_CONTAINER") != "" {
				list, err := micropodv1.NewContainerServiceClient(conn).ListContainers(ctx, &micropodv1.Empty{})
				if err != nil {
					t.Fatalf("ListContainers: %v", err)
				}
				t.Logf("ListContainers: %d", len(list.GetContainers()))
				_, err = micropodv1.NewContainerServiceClient(conn).GetContainer(ctx, &micropodv1.ContainerRef{Id: "no-such-container-h2"})
				if status.Code(err) != codes.NotFound {
					t.Fatalf("an unknown id: %v, want NotFound", err)
				}
			}
		})
	}
}

// 100 concurrent calls on one connection, each a stream of its own.
func TestInteropGRPCConcurrent(t *testing.T) {
	for _, target := range interopTargets(t) {
		t.Run(target.name, func(t *testing.T) {
			client := micropodv1.NewSystemServiceClient(dial(t, target))
			var wg sync.WaitGroup
			errs := make(chan error, 100)
			for i := 0; i < 100; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
					defer cancel()
					if _, err := client.Ping(ctx, &micropodv1.Empty{}); err != nil {
						errs <- err
					}
				}()
			}
			wg.Wait()
			close(errs)
			for err := range errs {
				t.Errorf("concurrent Ping: %v", err)
			}
		})
	}
}

func TestInteropGRPCDeadline(t *testing.T) {
	for _, target := range interopTargets(t) {
		t.Run(target.name, func(t *testing.T) {
			conn := dial(t, target)
			// Watch holds its stream open: the 50 ms deadline ends it.
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			watch, err := healthpb.NewHealthClient(conn).Watch(ctx, &healthpb.HealthCheckRequest{})
			if err != nil {
				t.Fatal(err)
			}
			if first, err := watch.Recv(); err != nil || first.GetStatus() != healthpb.HealthCheckResponse_SERVING {
				t.Fatalf("Watch's first status: %v %v", first, err)
			}
			if _, err := watch.Recv(); status.Code(err) != codes.DeadlineExceeded {
				t.Fatalf("after the deadline: %v", err)
			}
			// The connection still serves.
			ping, err := micropodv1.NewSystemServiceClient(conn).Ping(context.Background(), &micropodv1.Empty{})
			if err != nil {
				t.Fatalf("Ping after: %v %v", ping, err)
			}
		})
	}
}

func TestInteropGRPCStreams(t *testing.T) {
	id := os.Getenv("MICROPOD_INTEROP_CONTAINER")
	if id == "" {
		t.Skip("set MICROPOD_INTEROP_CONTAINER to a running container that logs")
	}
	for _, target := range interopTargets(t) {
		t.Run(target.name, func(t *testing.T) {
			client := micropodv1.NewContainerServiceClient(dial(t, target))
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			// To its end: no follow.
			stream, err := client.StreamContainerLogs(ctx, &micropodv1.StreamLogsRequest{Id: id, Tail: 5, NoFollow: true})
			if err != nil {
				t.Fatal(err)
			}
			lines := 0
			for {
				_, err := stream.Recv()
				if errors.Is(err, io.EOF) {
					break
				}
				if err != nil {
					t.Fatalf("after %d lines: %v", lines, err)
				}
				lines++
			}
			if lines == 0 {
				t.Fatal("no lines")
			}
			// Cancelled mid-stream.
			follow, cancelFollow := context.WithCancel(ctx)
			stream, err = client.StreamContainerLogs(follow, &micropodv1.StreamLogsRequest{Id: id, Tail: 1})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := stream.Recv(); err != nil {
				t.Fatal(err)
			}
			cancelFollow()
			for {
				if _, err := stream.Recv(); err != nil {
					if status.Code(err) != codes.Canceled {
						t.Fatalf("cancelled: %v", err)
					}
					break
				}
			}
			// An unknown container ends the stream with the code the same
			// handler answers a Connect client over HTTP/1.1.
			unknown := &micropodv1.StreamLogsRequest{Id: "no-such-container-h2", NoFollow: true}
			stream, err = client.StreamContainerLogs(ctx, unknown)
			if err == nil {
				for err == nil {
					_, err = stream.Recv()
				}
			}
			h1 := connectClient(target)
			h1Stream, h1Err := h1.StreamContainerLogs(ctx, connect.NewRequest(unknown))
			if h1Err == nil {
				for h1Stream.Receive() {
				}
				h1Err = h1Stream.Err()
			}
			if h1Err == nil || uint32(status.Code(err)) != uint32(connect.CodeOf(h1Err)) {
				t.Fatalf("unknown container's stream: gRPC %v, Connect over HTTP/1.1 %v", err, h1Err)
			}
			t.Logf("unknown container's stream: %v (Connect: %v)", status.Code(err), connect.CodeOf(h1Err))
		})
	}
}

// The flood soak: one container's logs followed for N seconds. A GOAWAY
// (the control-frame bound tripping on grpc-go's BDP pings) fails it.
func TestInteropGRPCLogFlood(t *testing.T) {
	id := os.Getenv("MICROPOD_INTEROP_CONTAINER")
	seconds, _ := strconv.Atoi(os.Getenv("MICROPOD_INTEROP_FLOOD_SECONDS"))
	if id == "" || seconds == 0 {
		t.Skip("set MICROPOD_INTEROP_CONTAINER and MICROPOD_INTEROP_FLOOD_SECONDS")
	}
	for _, target := range interopTargets(t) {
		t.Run(target.name, func(t *testing.T) {
			client := micropodv1.NewContainerServiceClient(dial(t, target))
			ctx, cancel := context.WithTimeout(context.Background(), time.Duration(seconds)*time.Second)
			defer cancel()
			stream, err := client.StreamContainerLogs(ctx, &micropodv1.StreamLogsRequest{Id: id, Tail: 1})
			if err != nil {
				t.Fatal(err)
			}
			lines, bytes := 0, 0
			for {
				msg, err := stream.Recv()
				if err != nil {
					if status.Code(err) != codes.DeadlineExceeded {
						t.Fatalf("after %d lines (%d bytes): %v", lines, bytes, err)
					}
					break
				}
				lines++
				bytes += len(msg.GetText())
			}
			t.Logf("flood: %d lines, %d bytes in %d s", lines, bytes, seconds)
			fmt.Printf("FLOOD %s lines=%d bytes=%d seconds=%d\n", target.name, lines, bytes, seconds)
		})
	}
}

func TestInteropConnectOverH2C(t *testing.T) {
	for _, target := range interopTargets(t) {
		t.Run(target.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			for name, opts := range map[string][]micropod.Option{
				"connect proto": {micropod.WithHTTP2()},
				"connect json":  {micropod.WithHTTP2(), micropod.WithConnectOptions(connect.WithProtoJSON())},
				"grpc":          {micropod.WithGRPC()},
				"grpc json":     {micropod.WithGRPC(), micropod.WithConnectOptions(connect.WithProtoJSON())},
				"http1":         {},
			} {
				client := connectClient(target, opts...)
				ping, err := client.Ping(ctx, connect.NewRequest(&micropodv1.Empty{}))
				if err != nil {
					t.Fatalf("%s Ping: %v", name, err)
				}
				t.Logf("%s Ping: %s", name, ping.Msg.GetStatus())
				if id := os.Getenv("MICROPOD_INTEROP_CONTAINER"); id != "" {
					stream, err := client.StreamContainerLogs(ctx, connect.NewRequest(&micropodv1.StreamLogsRequest{Id: id, Tail: 3, NoFollow: true}))
					if err != nil {
						t.Fatalf("%s logs: %v", name, err)
					}
					lines := 0
					for stream.Receive() {
						lines++
					}
					if err := stream.Err(); err != nil || lines == 0 {
						t.Fatalf("%s logs: %d lines, %v", name, lines, err)
					}
				}
			}
		})
	}
}

var _ = net.Dial
