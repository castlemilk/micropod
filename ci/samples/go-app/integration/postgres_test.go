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
	tcexec "github.com/testcontainers/testcontainers-go/exec"
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
		// During initdb the image starts a temporary Unix-socket-only server. TCP opens
		// once the entrypoint has exec'd the final postmaster, which can shut down cleanly.
		WaitingFor: wait.ForExec([]string{"pg_isready", "-q", "-h", "127.0.0.1", "-U", "ci", "-d", "ci"}).
			WithStartupTimeout(2 * time.Minute),
	}
	profile := configurePGProfile(t, &req)
	endStart := profile.span("create_to_ready")
	pg, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	endStart()
	if pg != nil {
		if profile != nil {
			profile.Container = pg.GetContainerID()
		}
		t.Cleanup(func() {
			defer profile.span("teardown")()
			cleanup, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			if err := pg.Terminate(cleanup); err != nil {
				t.Errorf("terminate postgres: %v", err)
			}
		})
	}
	if err != nil {
		t.Fatalf("start postgres: %v", err)
	}

	const sql = "CREATE TABLE ci_probe (value integer NOT NULL); INSERT INTO ci_probe VALUES (42); SELECT value FROM ci_probe;"
	endSQL := profile.span("sql")
	code, outReader, err := pg.Exec(ctx, []string{"psql", "-XqAt", "-w", "-h", "127.0.0.1", "-U", "ci", "-d", "ci",
		"-v", "ON_ERROR_STOP=1", "-c", sql}, tcexec.WithEnv([]string{"PGPASSWORD=" + req.Env["POSTGRES_PASSWORD"]}), tcexec.Multiplexed())
	if err != nil {
		endSQL()
		t.Fatalf("exec SQL check: %v", err)
	}
	out, err := io.ReadAll(outReader)
	endSQL()
	if err != nil || code != 0 || strings.TrimSpace(string(out)) != "42" {
		t.Fatalf("SQL check: exit %d, output %q, read error %v", code, out, err)
	}
	t.Logf("verified SQL round trip on the final TCP server %s", pg.GetContainerID())
}
