package server_test

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"connectrpc.com/connect"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
	"micropod/api/internal/clicli"
	"micropod/api/internal/server"
)

func newTestServer(t *testing.T) (micropodv1connect.MicropodServiceClient, func()) {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	stateDir := t.TempDir()
	// Point the CLI client at the mock + a per-test state dir.
	t.Setenv("MICROPOD_CONTAINER_CLI_PATH", filepath.Join(root, "Tests", "MicropodIntegrationTests", "Support", "mock-container"))
	t.Setenv("MICROPOD_MOCK_STATE_DIR", stateDir)

	cli := clicli.New()
	_, handler := micropodv1connect.NewMicropodServiceHandler(server.New(cli))
	srv := httptest.NewServer(handler)
	client := micropodv1connect.NewMicropodServiceClient(srv.Client(), srv.URL)
	return client, srv.Close
}

func TestGetSystem(t *testing.T) {
	client, close := newTestServer(t)
	defer close()
	res, err := client.GetSystem(context.Background(), connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	if res.Msg.GetStatus().GetStatus() != "running" {
		t.Fatalf("expected running, got %q", res.Msg.GetStatus().GetStatus())
	}
	if res.Msg.GetStatus().GetCliVersion() != "1.2.3" {
		t.Fatalf("expected cli 1.2.3, got %q", res.Msg.GetStatus().GetCliVersion())
	}
}

func TestContainerLifecycleViaConnect(t *testing.T) {
	client, close := newTestServer(t)
	defer close()
	ctx := context.Background()

	name := "ctl-web"
	run, err := client.RunContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{
		Image: "nginx:1.27", Name: &name, Env: []string{"API=go"},
	}))
	if err != nil {
		t.Fatal(err)
	}
	id := run.Msg.GetId()
	if id == "" {
		t.Fatal("run returned empty id")
	}

	list, err := client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
	if err != nil {
		t.Fatal(err)
	}
	var mine *micropodv1.Container
	for _, c := range list.Msg.GetContainers() {
		if c.GetId() == id {
			mine = c
		}
	}
	if mine == nil {
		t.Fatal("container not listed")
	}
	if mine.GetState() != "running" {
		t.Fatalf("expected running, got %s", mine.GetState())
	}
	if mine.GetImage() != "nginx:1.27" {
		t.Fatalf("unexpected image %q", mine.GetImage())
	}
	foundEnv := false
	for _, e := range mine.GetEnv() {
		if e == "API=go" {
			foundEnv = true
		}
	}
	if !foundEnv {
		t.Fatal("env did not round-trip")
	}

	// create-without-start
	createdName := "ctl-created"
	created, err := client.CreateContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{
		Image: "alpine:3.20", Name: &createdName,
	}))
	if err != nil {
		t.Fatal(err)
	}
	list2, _ := client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
	for _, c := range list2.Msg.GetContainers() {
		if c.GetId() == created.Msg.GetId() && c.GetState() != "created" {
			t.Fatalf("create must not start the container (state=%s)", c.GetState())
		}
	}

	// stop / restart / delete
	if _, err := client.StopContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RestartContainer(ctx, connect.NewRequest(&micropodv1.ContainerRef{Id: id})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: id, Force: true})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: created.Msg.GetId(), Force: true})); err != nil {
		t.Fatal(err)
	}
}

func TestStreamLogsAndPull(t *testing.T) {
	client, close := newTestServer(t)
	defer close()
	ctx := context.Background()

	name := "ctl-logs"
	run, err := client.RunContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{
		Image: "nginx:1.27", Name: &name, Arguments: []string{"sh", "-c", "echo boot-line; sleep 30"},
	}))
	if err != nil {
		t.Fatal(err)
	}
	defer client.DeleteContainer(ctx, connect.NewRequest(&micropodv1.DeleteContainerRequest{Id: run.Msg.GetId(), Force: true}))

	stream, err := client.StreamContainerLogs(ctx, connect.NewRequest(&micropodv1.StreamLogsRequest{Id: name, Tail: 5}))
	if err != nil {
		t.Fatal(err)
	}
	gotLine := false
	for stream.Receive() {
		if stream.Msg().GetText() != "" {
			gotLine = true
			break
		}
	}
	if stream.Err() != nil {
		t.Fatal(stream.Err())
	}
	if !gotLine {
		t.Fatal("no log lines received")
	}

	// Pull with progress streaming.
	pull, err := client.PullImage(ctx, connect.NewRequest(&micropodv1.PullImageRequest{Reference: "redis:7"}))
	if err != nil {
		t.Fatal(err)
	}
	lines := 0
	for pull.Receive() {
		lines++
	}
	if pull.Err() != nil {
		t.Fatal(pull.Err())
	}
	if lines == 0 {
		t.Fatal("pull produced no progress lines")
	}
	_ = os.Getenv
}
