package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	dockerHealthInterval      = 30 * time.Second
	dockerHealthTimeout       = 30 * time.Second
	dockerHealthStartInterval = 5 * time.Second
	dockerHealthRetries       = 3
	dockerHealthHistory       = 5
	dockerHealthOutputLimit   = 4096
	dockerHealthStartTimeout  = 30 * time.Second
	dockerHealthReapTimeout   = 5 * time.Second
	dockerHealthDrainTimeout  = 250 * time.Millisecond

	dockerHealthStarting  = "starting"
	dockerHealthHealthy   = "healthy"
	dockerHealthUnhealthy = "unhealthy"
)

type dockerHealthConfig struct {
	Test          []string      `json:",omitempty"`
	Interval      time.Duration `json:",omitempty"`
	Timeout       time.Duration `json:",omitempty"`
	StartPeriod   time.Duration `json:",omitempty"`
	StartInterval time.Duration `json:",omitempty"`
	Retries       int           `json:",omitempty"`
}

func (h *dockerHealthConfig) validate() error {
	if h == nil {
		return nil
	}
	for _, field := range []struct {
		name string
		time time.Duration
	}{
		{"Interval", h.Interval}, {"Timeout", h.Timeout},
		{"StartPeriod", h.StartPeriod}, {"StartInterval", h.StartInterval},
	} {
		if field.time != 0 && field.time < time.Millisecond {
			return fmt.Errorf("%s in Healthcheck cannot be less than 1ms", field.name)
		}
	}
	if h.Retries < 0 {
		return errors.New("Retries in Healthcheck cannot be negative")
	}
	if len(h.Test) == 0 {
		return nil
	}
	switch h.Test[0] {
	case "NONE":
		if len(h.Test) == 1 {
			return nil
		}
	case "CMD":
		if len(h.Test) > 1 && h.Test[1] != "" && validDockerHealthArgs(h.Test[1:]) {
			return nil
		}
	case "CMD-SHELL":
		if len(h.Test) > 1 && validDockerHealthArgs(h.Test[1:]) {
			return nil
		}
	}
	return errors.New("invalid Healthcheck.Test: expected NONE, CMD or CMD-SHELL")
}

func validDockerHealthArgs(args []string) bool {
	return !slices.ContainsFunc(args, func(arg string) bool { return strings.ContainsRune(arg, 0) })
}

func validDockerHealthShell(shell []string) bool {
	return len(shell) == 0 || shell[0] != "" && validDockerHealthArgs(shell)
}

func (h *dockerHealthConfig) command(shell []string) []string {
	if h == nil || len(h.Test) < 2 {
		return nil
	}
	switch h.Test[0] {
	case "CMD":
		return h.Test[1:]
	case "CMD-SHELL":
		if len(shell) == 0 {
			shell = []string{"/bin/sh", "-c"}
		}
		return append(slices.Clone(shell), h.Test[1:]...)
	default:
		return nil
	}
}

func mergeDockerHealth(requested, inherited *dockerHealthConfig) *dockerHealthConfig {
	if requested == nil {
		return inherited
	}
	if inherited == nil {
		return requested
	}
	merged := *requested
	if len(merged.Test) == 0 {
		merged.Test = inherited.Test
	}
	if merged.Interval == 0 {
		merged.Interval = inherited.Interval
	}
	if merged.Timeout == 0 {
		merged.Timeout = inherited.Timeout
	}
	if merged.StartPeriod == 0 {
		merged.StartPeriod = inherited.StartPeriod
	}
	if merged.StartInterval == 0 {
		merged.StartInterval = inherited.StartInterval
	}
	if merged.Retries == 0 {
		merged.Retries = inherited.Retries
	}
	return &merged
}

type dockerHealthResult struct {
	Start, End time.Time
	ExitCode   int32
	Output     string
}

type dockerHealthState struct {
	Status        string
	FailingStreak int
	Log           []dockerHealthResult
}

func (h *dockerHealthState) snapshot() dockerHealthState {
	return dockerHealthState{Status: h.Status, FailingStreak: h.FailingStreak, Log: slices.Clone(h.Log)}
}

func (h *dockerHealthState) interval(config *dockerHealthConfig, elapsed time.Duration) time.Duration {
	if h.Status == dockerHealthStarting && elapsed < config.StartPeriod {
		if config.StartInterval != 0 {
			return config.StartInterval
		}
		return dockerHealthStartInterval
	}
	if config.Interval != 0 {
		return config.Interval
	}
	return dockerHealthInterval
}

func (h *dockerHealthState) record(config *dockerHealthConfig, started time.Time, result dockerHealthResult) {
	if len(h.Log) >= dockerHealthHistory {
		copy(h.Log, h.Log[len(h.Log)-dockerHealthHistory+1:])
		h.Log = h.Log[:dockerHealthHistory-1]
	}
	h.Log = append(h.Log, result)
	if result.ExitCode == 0 {
		h.FailingStreak = 0
		h.Status = dockerHealthHealthy
		return
	}
	if h.Status == dockerHealthStarting && result.Start.Sub(started) < config.StartPeriod {
		return
	}
	retries := config.Retries
	if retries == 0 {
		retries = dockerHealthRetries
	}
	h.FailingStreak++
	if h.FailingStreak >= retries {
		h.Status = dockerHealthUnhealthy
	}
}

type dockerHealthMonitor struct {
	target  string
	started time.Time
	cancel  context.CancelFunc
	done    chan struct{}
}

// Called with s.mu held after the runtime task starts and before responding to start.
func (s *dockerEngine) startDockerHealth(ctx context.Context, c *dockerContainer) {
	config := c.Config.Healthcheck
	command := config.command(c.Config.Shell)
	if len(command) == 0 {
		return
	}
	if c.Health == nil {
		c.Health = &dockerHealthState{Log: make([]dockerHealthResult, 0, dockerHealthHistory)}
	}
	c.Health.Status = dockerHealthStarting
	c.Health.FailingStreak = 0
	ctx, cancel := context.WithCancel(ctx)
	monitor := &dockerHealthMonitor{target: c.RuntimeID, started: time.Now(), cancel: cancel, done: make(chan struct{})}
	c.healthMonitor = monitor
	go s.monitorDockerHealth(ctx, c, monitor, config, command, c.Health.interval(config, 0))
}

func (s *dockerEngine) stopDockerHealth(c *dockerContainer) {
	s.mu.Lock()
	monitor := c.healthMonitor
	if monitor != nil {
		c.healthMonitor = nil
		// An inactive Docker health monitor reports unhealthy. Keep the last
		// probe streak and history, and publish events only for probe results.
		c.Health.Status = dockerHealthUnhealthy
	}
	s.mu.Unlock()
	if monitor != nil {
		monitor.cancel()
		<-monitor.done
	}
}

func (s *dockerEngine) monitorDockerHealth(ctx context.Context, c *dockerContainer, monitor *dockerHealthMonitor, config *dockerHealthConfig, command []string, interval time.Duration) {
	defer close(monitor.done)
	timer := time.NewTimer(interval)
	defer timer.Stop()
	timeout := config.Timeout
	if timeout == 0 {
		timeout = dockerHealthTimeout
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		if ctx.Err() != nil {
			return
		}
		result, reapErr := s.runDockerHealthProbe(ctx, monitor.target, command, timeout)
		s.mu.Lock()
		if !s.recordDockerHealth(ctx, c, monitor, config, result) {
			s.mu.Unlock()
			return
		}
		interval = c.Health.interval(config, time.Since(monitor.started))
		s.mu.Unlock()
		if reapErr != nil {
			// Do not accumulate probes if the shim cannot account for this one.
			// Container retirement will still reclaim the generation's tasks.
			log.Printf("health check process cleanup for container %s: %v", c.ID, reapErr)
			return
		}
		timer.Reset(interval)
	}
}

// Call with s.mu held. The monitor pointer and task ID fence restart/removal.
func (s *dockerEngine) recordDockerHealth(ctx context.Context, c *dockerContainer, monitor *dockerHealthMonitor, config *dockerHealthConfig, result dockerHealthResult) bool {
	if ctx.Err() != nil || c.healthMonitor != monitor || c.RuntimeID != monitor.target || c.Phase != "running" || c.removed {
		return false
	}
	previous := c.Health.Status
	c.Health.record(config, monitor.started, result)
	if c.Health.Status != previous {
		s.containerEvent(c, "health_status: "+c.Health.Status, nil)
	}
	return true
}

type dockerHealthOutput struct {
	mu        sync.Mutex
	data      []byte
	truncated bool
}

func (b *dockerHealthOutput) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	keep := min(len(p), dockerHealthOutputLimit-len(b.data))
	b.data = append(b.data, p[:keep]...)
	b.truncated = b.truncated || keep != len(p)
	return len(p), nil
}

func (b *dockerHealthOutput) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.truncated {
		return string(b.data) + "..."
	}
	return string(b.data)
}

func (s *dockerEngine) runDockerHealthProbe(ctx context.Context, target string, command []string, timeout time.Duration) (result dockerHealthResult, reapErr error) {
	result.Start = time.Now().UTC()
	result.ExitCode = -1
	defer func() { result.End = time.Now().UTC() }()
	setup, cancel := context.WithTimeout(dockerExecContext(ctx), dockerHealthStartTimeout)
	probe, _, err := s.startNativeTaskExec(setup, engineID(), &dockerExec{target: target, cmd: command}, nil, true)
	cancel()
	if probe != nil {
		defer probe.pipes.close()
		defer probe.cancelWait()
	}
	if err != nil {
		if probe != nil {
			reapErr = probe.reapDockerHealthExec(true)
		}
		result.Output = boundedDockerHealthText(errors.Join(err, reapErr).Error())
		return result, reapErr
	}

	output := &dockerHealthOutput{}
	done := make(chan struct{})
	go func() {
		var readers sync.WaitGroup
		for _, pipe := range []*os.File{probe.pipes.stdout, probe.pipes.stderr} {
			readers.Go(func() { _, _ = io.Copy(output, pipe) })
		}
		readers.Wait()
		close(done)
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	var diagnostic string
	var force bool
	select {
	case exit := <-probe.exits:
		if exit.err == nil {
			result.ExitCode = exit.code
		} else {
			diagnostic = exit.err.Error()
			force = true
		}
	case <-timer.C:
		diagnostic = fmt.Sprintf("Health check exceeded timeout (%v)", timeout)
		force = true
	case <-ctx.Done():
		diagnostic = ctx.Err().Error()
		force = true
	}
	reapErr = probe.reapDockerHealthExec(force)
	drain := time.NewTimer(dockerHealthDrainTimeout)
	defer drain.Stop()
	select {
	case <-done:
	case <-drain.C:
		probe.closeOutput(done, nil)
	}
	result.Output = output.String()
	if reapErr != nil {
		if diagnostic != "" {
			diagnostic += "\n"
		}
		diagnostic += reapErr.Error()
		result.ExitCode = -1
	}
	if diagnostic != "" {
		if result.Output == "" {
			result.Output = diagnostic
		} else {
			result.Output = diagnostic + ": " + result.Output
		}
		result.Output = boundedDockerHealthText(result.Output)
	}
	return result, reapErr
}

func boundedDockerHealthText(text string) string {
	if len(text) > dockerHealthOutputLimit {
		return text[:dockerHealthOutputLimit] + "..."
	}
	return text
}

// Only signal the acknowledged ExecID. Use a new deadline because the probe's
// context may have expired. DeleteProcess must acknowledge retirement before
// another check can start.
func (p *nativeDockerExec) reapDockerHealthExec(force bool) error {
	ctx, cancel := context.WithTimeout(p.ctx, dockerHealthReapTimeout)
	defer cancel()
	if force {
		_, err := p.tasks.Kill(ctx, &tasks.KillRequest{
			ContainerID: p.target, ExecID: p.id, Signal: uint32(unix.SIGKILL),
		})
		switch status.Code(err) {
		case codes.OK:
			_, err = p.tasks.Wait(ctx, &tasks.WaitRequest{ContainerID: p.target, ExecID: p.id})
			if err != nil && status.Code(err) != codes.NotFound {
				return fmt.Errorf("wait for killed health check: %w", err)
			}
		case codes.NotFound, codes.FailedPrecondition:
			// The task may have stopped already. Delete verifies this.
		default:
			return fmt.Errorf("kill health check: %w", err)
		}
	}
	_, err := p.tasks.DeleteProcess(ctx, &tasks.DeleteProcessRequest{ContainerID: p.target, ExecID: p.id})
	if err != nil && status.Code(err) != codes.NotFound {
		return fmt.Errorf("reap health check: %w", err)
	}
	return nil
}
