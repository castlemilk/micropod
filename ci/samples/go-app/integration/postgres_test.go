//go:build integration

// Postgres integration test driven by testcontainers-go against whatever
// Docker endpoint DOCKER_HOST points at — locally that is the
// micropod-docker-shim, which transparently redirects the Ryuk reaper's
// docker.sock mount to its TCP listener over the VM bridge.
package integration

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

func TestPostgresReady(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	req := testcontainers.ContainerRequest{
		Image:        "postgres:16",
		ExposedPorts: []string{"5432/tcp"},
		Env: map[string]string{
			"POSTGRES_USER":     "ci",
			"POSTGRES_PASSWORD": "ci",
			"POSTGRES_DB":       "ci",
		},
		WaitingFor: wait.ForLog("database system is ready to accept connections").
			WithStartupTimeout(2 * time.Minute),
	}
	pg, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() {
		if err := pg.Terminate(context.Background()); err != nil {
			t.Logf("terminate: %v", err)
		}
	})

	// pg_isready ships in the image: no client library needed to prove the
	// container is up, reachable, and exec works through the shim.
	code, outReader, err := pg.Exec(ctx, []string{"pg_isready", "-U", "ci", "-d", "ci"})
	if err != nil {
		t.Fatalf("exec pg_isready: %v", err)
	}
	out, _ := io.ReadAll(outReader)
	if code != 0 {
		t.Fatalf("pg_isready exit %d: %s", code, out)
	}
	if !strings.Contains(string(out), "accepting connections") {
		t.Fatalf("unexpected pg_isready output: %s", out)
	}
	t.Logf("pg_isready: %s", strings.TrimSpace(string(out)))
}
