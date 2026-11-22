//go:build integration

package integration

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	tc "github.com/testcontainers/testcontainers-go"
	tcexec "github.com/testcontainers/testcontainers-go/exec"
	"github.com/testcontainers/testcontainers-go/wait"
)

// This observer is enabled only by the local PostgreSQL fixture benchmark.
// All variants execute the same TestPostgresReady SQL, wait and cleanup.
type pgProfile struct {
	StartUnixUS        int64 `json:"start_unix_us"`
	start              time.Time
	Spans              map[string][2]int64 `json:"spans_us"`
	Container          string              `json:"container,omitempty"`
	Volumes            []string            `json:"volumes"`
	RestoreMicros      *int64              `json:"fixture_restore_us,omitempty"`
	AfterRestoreMicros *int64              `json:"materialized_to_tcp_ready_us,omitempty"`
	Kernel             string              `json:"job_cgroup,omitempty"`
	Passed             bool                `json:"passed"`
}

type pgProfileWait struct {
	wait.Strategy
	profile *pgProfile
}

// Stamp the first successful, unchanged pg_isready command on the same guest
// clock as the fixture. This adds no Docker RPC or extra readiness poll.
type pgReadyTarget struct{ wait.StrategyTarget }

func (t pgReadyTarget) Exec(ctx context.Context, cmd []string, opts ...tcexec.ProcessOption) (int, io.Reader, error) {
	const probe = `"$@" || exit $?; read -r stamp _ < /proc/uptime && printf '%s\n' "$stamp" > /tmp/micropod-tcp-ready`
	wrapped := append([]string{"sh", "-c", probe, "pg-readiness"}, cmd...)
	return t.StrategyTarget.Exec(ctx, wrapped, opts...)
}

func (w pgProfileWait) WaitUntilReady(ctx context.Context, target wait.StrategyTarget) error {
	defer w.profile.span("readiness")()
	return w.Strategy.WaitUntilReady(ctx, pgReadyTarget{target})
}

func (p *pgProfile) span(name string) func() {
	if p == nil {
		return func() {}
	}
	begin := time.Since(p.start).Microseconds()
	return func() { p.Spans[name] = [2]int64{begin, time.Since(p.start).Microseconds()} }
}

func configurePGProfile(t *testing.T, req *tc.ContainerRequest) *pgProfile {
	t.Helper()
	image := os.Getenv("MICROPOD_PG_PROFILE_IMAGE")
	if image == "" {
		return nil
	}
	run := os.Getenv("MICROPOD_PG_PROFILE_RUN")
	_, err := hex.DecodeString(run)
	if len(run) != 32 || err != nil {
		t.Fatal("invalid PostgreSQL benchmark run ID")
	}
	req.Image = image
	req.Env["POSTGRES_PASSWORD"] = hex.EncodeToString(randomBytes(t))
	// Match the empty-catalog build's local and TCP authentication rules.
	req.Env["POSTGRES_INITDB_ARGS"] = "--auth-local=trust --auth-host=scram-sha-256"
	req.Labels = map[string]string{"io.micropod.postgres-profile": run}
	start := time.Now()
	p := &pgProfile{start: start, StartUnixUS: start.UnixMicro(), Spans: make(map[string][2]int64)}
	pWait := pgProfileWait{req.WaitingFor, p}
	req.WaitingFor = pWait
	t.Cleanup(func() {
		p.Passed = !t.Failed()
		data, err := json.Marshal(p)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("MP_PG_RESULT %s", data)
	})
	return p
}

func randomBytes(t *testing.T) []byte {
	t.Helper()
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

func (p *pgProfile) observe(ctx context.Context, pg tc.Container) error {
	defer p.span("observation")()
	inspection, err := pg.Inspect(ctx)
	if err != nil {
		return err
	}
	for _, mount := range inspection.Mounts {
		if mount.Type == "volume" {
			p.Volumes = append(p.Volumes, mount.Name)
		}
	}
	logs, err := pg.Logs(ctx)
	if err != nil {
		return err
	}
	defer logs.Close()
	body, err := io.ReadAll(io.LimitReader(logs, 1<<20))
	if err != nil {
		return err
	}
	marks := map[string]float64{}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 3 || fields[0] != "MP_PG_FIXTURE" {
			continue
		}
		if _, exists := marks[fields[1]]; exists {
			return fmt.Errorf("duplicate PostgreSQL marker %s", fields[1])
		}
		value, err := strconv.ParseFloat(fields[2], 64)
		if err != nil {
			return err
		}
		marks[fields[1]] = value
	}
	start, ok1 := marks["begin"]
	end, ok2 := marks["materialized"]
	if !ok1 || !ok2 || end < start {
		return fmt.Errorf("incomplete PostgreSQL fixture markers %v", marks)
	}
	us := int64((end-start)*1e6 + .5)
	p.RestoreMicros = &us
	code, r, err := pg.Exec(ctx, []string{"sh", "-ec", `cat /tmp/micropod-tcp-ready
    for f in cpu.stat io.stat cpu.pressure io.pressure memory.events; do
        test -r "/sys/fs/cgroup/$f" || continue
        echo "[$f]"; cat "/sys/fs/cgroup/$f"
    done`}, tcexec.Multiplexed())
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("read PostgreSQL cgroup counters: exit %d", code)
	}
	raw, err := io.ReadAll(io.LimitReader(r, 32<<10))
	if err != nil {
		return err
	}
	stamp, counters, ok := strings.Cut(string(raw), "\n")
	ready, err := strconv.ParseFloat(stamp, 64)
	if !ok || err != nil || ready < end {
		return fmt.Errorf("invalid final TCP readiness timestamp %q", stamp)
	}
	after := int64((ready-end)*1e6 + .5)
	p.AfterRestoreMicros = &after
	p.Kernel = counters
	return nil
}
