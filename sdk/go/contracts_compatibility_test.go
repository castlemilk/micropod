package micropod

import (
	"testing"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

// These fields arrived on independent branches. Regenerating either contract
// must retain both consumers, including the optional per-VM init image, and
// the version manifest and update state rig controllers read from Ping.
func TestGeneratedContractsRetainInitImageAndRootlessSandbox(t *testing.T) {
	for _, tc := range []struct {
		name    string
		message proto.Message
		fresh   func() proto.Message
	}{
		{"native init image", &micropodv1.RunContainerRequest{InitImage: proto.String("registry.example/init@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")}, func() proto.Message { return &micropodv1.RunContainerRequest{} }},
		{"private rootless sandbox", &micropodv1.StartSandboxRequest{Options: &micropodv1.SandboxOptions{RootlessDocker: true, DiskSizeMib: 8192}}, func() proto.Message { return &micropodv1.StartSandboxRequest{} }},
		{"ping version manifest", &micropodv1.PingResponse{
			Status: "running", ApiServerVersion: "1.5.0", AppleApiServerVersion: "1.5.0",
			MicropodVersion: "0.14.0", SourceRevision: "33eea649a1b2c3d4e5f60718293a4b5c6d7e8f90", ProtocolVersion: 1,
			PeerProtocol: &micropodv1.ProtocolRange{Name: "micropod-runtime-coordination", MinVersion: 1, MaxVersion: 1},
			Components:   []*micropodv1.ComponentVersion{{Name: "docker-shim", Version: "0.13.0", Revision: "unknown", State: "running", Detail: "retained payload"}},
			UpdateState:  &micropodv1.UpdateState{Kind: micropodv1.UpdateState_KIND_UPGRADING, Scope: "runtime", Phase: "runtime-maintenance", OperationId: "8d6b9f5e-0000-4000-8000-000000000000"},
		}, func() proto.Message { return &micropodv1.PingResponse{} }},
		{"system snapshot version manifest", &micropodv1.SystemSnapshot{
			Status:          &micropodv1.SystemStatus{Status: "running", AppleApiServerVersion: "1.5.0"},
			MicropodVersion: "0.14.0", ProtocolVersion: 1,
			Components:  []*micropodv1.ComponentVersion{{Name: "kernel", Version: "6.18.35-197", Sha256: "ab", State: "installed"}},
			UpdateState: &micropodv1.UpdateState{Kind: micropodv1.UpdateState_KIND_CURRENT, Scope: "desktop", AvailableVersion: "0.14.1"},
		}, func() proto.Message { return &micropodv1.SystemSnapshot{} }},
		{"typed update status", &micropodv1.UpdateStatus{
			State: micropodv1.UpdateStatus_STATE_UPDATE_AVAILABLE, RestartBlockedReason: "no compatible payload",
			RestartGuard: "idle", Channel: "stable", WorkloadProtocol: 1, CurrentSourceRevision: "unknown", DesktopAdmission: "open",
			Transaction: &micropodv1.UpdateTransaction{OperationId: "op", Phase: "aborted", TargetVersion: "0.13.7", Detail: "rejected"},
			UpdateState: &micropodv1.UpdateState{Kind: micropodv1.UpdateState_KIND_ROLLED_BACK, Reason: "rejected", TargetVersion: "0.13.7"},
		}, func() proto.Message { return &micropodv1.UpdateStatus{} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			encoded, err := protojson.Marshal(tc.message)
			if err != nil {
				t.Fatal(err)
			}
			decoded := tc.fresh()
			if err := protojson.Unmarshal(encoded, decoded); err != nil {
				t.Fatal(err)
			}
			if !proto.Equal(tc.message, decoded) {
				t.Fatal("JSON transport lost the declared field")
			}
			binary, err := proto.Marshal(tc.message)
			if err != nil {
				t.Fatal(err)
			}
			decoded = tc.fresh()
			if err := proto.Unmarshal(binary, decoded); err != nil {
				t.Fatal(err)
			}
			if !proto.Equal(tc.message, decoded) {
				t.Fatal("protobuf transport lost the declared field")
			}
		})
	}
}
