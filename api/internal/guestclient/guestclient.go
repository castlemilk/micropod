// Package guestclient builds a gRPC client for vminitd, the agent running
// as PID 1 inside each container VM, over MicropodAPI's vsock bridge.
//
//	vminitd (guest :1024) ⇠ vsock ⇢ containerDial (XPC) ⇢ MicropodAPI
//	    /v1/containers/{id}/vsock/{port} ⇠ HTTP stream ⇢ grpc-go
//
// The generated stubs come from the vendored SandboxContext.proto —
// api/gen/com/apple/containerization/sandbox/v3.
package guestclient

import (
	"context"
	"fmt"
	"net"

	sandboxv3 "micropod/api/gen/com/apple/containerization/sandbox/v3"
	"micropod/api/internal/vsockdial"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// VminitdPort is the vsock port vminitd listens on inside every container VM.
const VminitdPort = 1024

// Dial opens a gRPC connection to the container's vminitd through the
// MicropodAPI bridge.
func Dial(ctx context.Context, containerID string) (*grpc.ClientConn, error) {
	baseURL := vsockdial.BridgeURL()
	conn, err := grpc.NewClient(
		"passthrough:///vminitd",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return vsockdial.Dial(ctx, baseURL, containerID, VminitdPort)
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("guestclient: dial container %s: %w", containerID, err)
	}
	return conn, nil
}

// Client returns a SandboxContext client for the container's vminitd.
// Callers close the underlying channel via the returned conn.
func Client(ctx context.Context, containerID string) (sandboxv3.SandboxContextClient, *grpc.ClientConn, error) {
	conn, err := Dial(ctx, containerID)
	if err != nil {
		return nil, nil, err
	}
	return sandboxv3.NewSandboxContextClient(conn), conn, nil
}
