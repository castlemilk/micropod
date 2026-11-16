package micropod

import (
	"testing"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

// These fields arrived on independent branches. Regenerating either contract
// must retain both consumers, including the optional per-VM init image.
func TestGeneratedContractsRetainInitImageAndRootlessSandbox(t *testing.T) {
	for _, tc := range []struct {
		name    string
		message proto.Message
		fresh   func() proto.Message
	}{
		{"native init image", &micropodv1.RunContainerRequest{InitImage: proto.String("registry.example/init@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")}, func() proto.Message { return &micropodv1.RunContainerRequest{} }},
		{"private rootless sandbox", &micropodv1.StartSandboxRequest{Options: &micropodv1.SandboxOptions{RootlessDocker: true, DiskSizeMib: 8192}}, func() proto.Message { return &micropodv1.StartSandboxRequest{} }},
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
