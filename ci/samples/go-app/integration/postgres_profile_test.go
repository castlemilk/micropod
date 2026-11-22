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
	Mode               string              `json:"fixture_mode"`
	PGData             string              `json:"pgdata"`
	RestoreMicros      *int64              `json:"fixture_restore_us,omitempty"`
	AfterRestoreMicros *int64              `json:"materialized_to_tcp_ready_us,omitempty"`
	Passed             bool                `json:"passed"`
}

type pgProfileWait struct {
	wait.Strategy
	profile *pgProfile
}

// Stamp the first successful, unchanged pg_isready command on the same guest
// clock as the fixture. This adds no Docker RPC or extra readiness poll.
type pgReadyTarget struct {
	wait.StrategyTarget
	profile *pgProfile
}

func (t pgReadyTarget) Exec(ctx context.Context, cmd []string, opts ...tcexec.ProcessOption) (int, io.Reader, error) {
	const probe = `"$@" || exit $?
read -r ready _ </proc/uptime
read -r begin </dev/shm/micropod-pg-begin
read -r materialized </dev/shm/micropod-pg-materialized
printf '%s %s %s %s %s\n' "$MICROPOD_PG_FIXTURE_MODE" "$PGDATA" "$begin" "$materialized" "$ready"`
	wrapped := append([]string{"sh", "-c", probe, "pg-readiness"}, cmd...)
	code, r, err := t.StrategyTarget.Exec(ctx, wrapped, opts...)
	if err != nil || code != 0 {
		return code, r, err
	}
	var begin, materialized, ready float64
	_, err = fmt.Fscan(io.LimitReader(r, 1024), &t.profile.Mode, &t.profile.PGData, &begin, &materialized, &ready)
	if err != nil || !(0 < begin && begin <= materialized && materialized <= ready) {
		return code, nil, fmt.Errorf("invalid PostgreSQL fixture timestamps (%v, %v, %v): %v", begin, materialized, ready, err)
	}
	restore := int64((materialized-begin)*1e6 + .5)
	after := int64((ready-materialized)*1e6 + .5)
	t.profile.RestoreMicros, t.profile.AfterRestoreMicros = &restore, &after
	return code, strings.NewReader(""), nil
}

func (w pgProfileWait) WaitUntilReady(ctx context.Context, target wait.StrategyTarget) error {
	defer w.profile.span("readiness")()
	return w.Strategy.WaitUntilReady(ctx, pgReadyTarget{target, w.profile})
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
