// Package clicli is a minimal, typed client for the Apple `container` CLI.
// It mirrors the JSON shapes MicropodCore consumes so the connect-go API
// server can talk to the runtime directly.
package clicli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// CLI is a handle to the container binary.
type CLI struct {
	Bin string
}

func New() *CLI {
	bin := "/usr/local/bin/container"
	if env := os.Getenv("MICROPOD_CONTAINER_CLI_PATH"); env != "" {
		bin = env
	}
	return &CLI{Bin: bin}
}

func (c *CLI) Available() bool {
	_, err := exec.LookPath(c.Bin)
	return err == nil
}

// Run executes a short command and returns trimmed stdout.
func (c *CLI) Run(ctx context.Context, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("`container %s` failed: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

// Stream runs a long-lived command, yielding stdout/stderr chunks.
func (c *CLI) Stream(ctx context.Context, fn func(line string) error, args ...string) error {
	cmd := exec.CommandContext(ctx, c.Bin, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		if err := fn(scanner.Text()); err != nil {
			_ = cmd.Process.Kill()
			return err
		}
	}
	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("stream command failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func decode[T any](output string) (T, error) {
	var value T
	if err := json.Unmarshal([]byte(output), &value); err != nil {
		return value, fmt.Errorf("parse output: %w", err)
	}
	return value, nil
}

func decodeList[T any](output string) ([]T, error) {
	dec := json.NewDecoder(strings.NewReader(output))
	var list []T
	if err := dec.Decode(&list); err != nil {
		var single T
		if err2 := json.Unmarshal([]byte(output), &single); err2 == nil {
			return []T{single}, nil
		}
		return nil, fmt.Errorf("parse list: %w", err)
	}
	return list, nil
}

// --- DTOs (mirror the CLI --format json shapes) ---

type ContainerListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		CreationDate string `json:"creationDate"`
		Image        *struct {
			Reference string `json:"reference"`
		} `json:"image"`
		Labels         map[string]string `json:"labels"`
		PublishedPorts []PublishedPort   `json:"publishedPorts"`
		InitProcess    *struct {
			Environment []string `json:"environment"`
		} `json:"initProcess"`
		Mounts []struct {
			Destination string `json:"destination"`
			Source      string `json:"source"`
			Type        map[string]any `json:"type"`
		} `json:"mounts"`
		Networks []struct {
			Network string `json:"network"`
		} `json:"networks"`
		Platform *struct {
			OS           string `json:"os"`
			Architecture string `json:"architecture"`
		} `json:"platform"`
		Resources *struct {
			CPUs          float64 `json:"cpus"`
			MemoryInBytes int64   `json:"memoryInBytes"`
		} `json:"resources"`
		ReadOnly bool `json:"readOnly"`
		UseInit  bool `json:"useInit"`
		Rosetta  bool `json:"rosetta"`
	} `json:"configuration"`
	Status struct {
		State string `json:"state"`
		Networks []struct {
			IPv4Address string `json:"ipv4Address"`
			Network     string `json:"network"`
		} `json:"networks"`
	} `json:"status"`
}

type PublishedPort struct {
	HostPort      int    `json:"hostPort"`
	ContainerPort int    `json:"containerPort"`
	Protocol      string `json:"protocol"`
}

type ImageListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		Name         string `json:"name"`
		CreationDate string `json:"creationDate"`
		Descriptor   *struct {
			Digest string `json:"digest"`
		} `json:"descriptor"`
	} `json:"configuration"`
	Variants []struct {
		Size     int64 `json:"size"`
		Platform *struct {
			OS           string `json:"os"`
			Architecture string `json:"architecture"`
		} `json:"platform"`
	} `json:"variants"`
}

type VolumeListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		Name         string            `json:"name"`
		Driver       string            `json:"driver"`
		Format       string            `json:"format"`
		SizeInBytes  int64             `json:"sizeInBytes"`
		Source       string            `json:"source"`
		CreationDate string            `json:"creationDate"`
		Labels       map[string]string `json:"labels"`
	} `json:"configuration"`
}

type NetworkListEntry struct {
	ID            string `json:"id"`
	Configuration struct {
		Name         string            `json:"name"`
		Mode         string            `json:"mode"`
		Plugin       string            `json:"plugin"`
		CreationDate string            `json:"creationDate"`
		Labels       map[string]string `json:"labels"`
	} `json:"configuration"`
	Status struct {
		IPv4Gateway string `json:"ipv4Gateway"`
		IPv4Subnet  string `json:"ipv4Subnet"`
		IPv6Subnet  string `json:"ipv6Subnet"`
	} `json:"status"`
}

type StatsEntry struct {
	ID               string `json:"id"`
	CPUUsageUsec     int64  `json:"cpuUsageUsec"`
	MemoryUsageBytes int64  `json:"memoryUsageBytes"`
	MemoryLimitBytes int64  `json:"memoryLimitBytes"`
	NetworkRxBytes   int64  `json:"networkRxBytes"`
	NetworkTxBytes   int64  `json:"networkTxBytes"`
	BlockReadBytes   int64  `json:"blockReadBytes"`
	BlockWriteBytes  int64  `json:"blockWriteBytes"`
	NumProcesses     int64  `json:"numProcesses"`
}

type SystemStatus struct {
	Status           string `json:"status"`
	AppRoot          string `json:"appRoot"`
	InstallRoot      string `json:"installRoot"`
	APIServerVersion string `json:"apiServerVersion"`
}

type SystemVersionEntry struct {
	AppName string `json:"appName"`
	Version string `json:"version"`
}

type DiskUsage struct {
	Containers DiskCategory `json:"containers"`
	Images     DiskCategory `json:"images"`
	Volumes    DiskCategory `json:"volumes"`
}

type DiskCategory struct {
	Total       int64 `json:"total"`
	Active      int64 `json:"active"`
	SizeInBytes int64 `json:"sizeInBytes"`
	Reclaimable int64 `json:"reclaimable"`
}

// --- Operations ---

func (c *CLI) SystemStatus(ctx context.Context) (*SystemStatus, error) {
	out, err := c.Run(ctx, "system", "status", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decode[*SystemStatus](out)
}

func (c *CLI) SystemVersion(ctx context.Context) (string, error) {
	out, err := c.Run(ctx, "system", "version", "--format", "json")
	if err != nil {
		return "", err
	}
	entries, err := decodeList[SystemVersionEntry](out)
	if err != nil || len(entries) == 0 {
		return "unknown", err
	}
	for _, e := range entries {
		if e.AppName == "container" {
			return e.Version, nil
		}
	}
	return entries[0].Version, nil
}

func (c *CLI) DiskUsage(ctx context.Context) (*DiskUsage, error) {
	out, err := c.Run(ctx, "system", "df", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decode[*DiskUsage](out)
}

func (c *CLI) ListContainers(ctx context.Context) ([]ContainerListEntry, error) {
	out, err := c.Run(ctx, "list", "--all", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[ContainerListEntry](out)
}

func (c *CLI) RunContainer(ctx context.Context, args ...string) (string, error) {
	out, err := c.Run(ctx, append([]string{"run"}, args...)...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

func (c *CLI) CreateContainer(ctx context.Context, args ...string) (string, error) {
	out, err := c.Run(ctx, append([]string{"create"}, args...)...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

func (c *CLI) SimpleAction(ctx context.Context, verb, id string) error {
	_, err := c.Run(ctx, verb, id)
	return err
}

func (c *CLI) DeleteContainer(ctx context.Context, id string, force bool) error {
	args := []string{"delete"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, id)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) StreamLogs(ctx context.Context, id string, tail int, boot bool, fn func(string) error) error {
	args := []string{"logs", "-n", strconv.Itoa(tail)}
	if boot {
		args = append(args, "--boot")
	}
	args = append(args, "--follow", id)
	return c.Stream(ctx, fn, args...)
}

func (c *CLI) ListImages(ctx context.Context) ([]ImageListEntry, error) {
	out, err := c.Run(ctx, "image", "list", "--format", "json", "--verbose")
	if err != nil {
		return nil, err
	}
	return decodeList[ImageListEntry](out)
}

func (c *CLI) PullImage(ctx context.Context, reference string, fn func(line string) error) error {
	return c.Stream(ctx, fn, "image", "pull", "--progress", "plain", reference)
}

func (c *CLI) DeleteImage(ctx context.Context, reference string, force bool) error {
	args := []string{"image", "delete"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, reference)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) ListVolumes(ctx context.Context) ([]VolumeListEntry, error) {
	out, err := c.Run(ctx, "volume", "list", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[VolumeListEntry](out)
}

func (c *CLI) CreateVolume(ctx context.Context, name, size string) error {
	args := []string{"volume", "create"}
	if size != "" {
		args = append(args, "-s", size)
	}
	args = append(args, name)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) DeleteVolume(ctx context.Context, name string) error {
	_, err := c.Run(ctx, "volume", "delete", name)
	return err
}

func (c *CLI) ListNetworks(ctx context.Context) ([]NetworkListEntry, error) {
	out, err := c.Run(ctx, "network", "list", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[NetworkListEntry](out)
}

func (c *CLI) CreateNetwork(ctx context.Context, name, subnet string, internal bool) error {
	args := []string{"network", "create"}
	if internal {
		args = append(args, "--internal")
	}
	if subnet != "" {
		args = append(args, "--subnet", subnet)
	}
	args = append(args, name)
	_, err := c.Run(ctx, args...)
	return err
}

func (c *CLI) DeleteNetwork(ctx context.Context, name string) error {
	_, err := c.Run(ctx, "network", "delete", name)
	return err
}

func (c *CLI) Stats(ctx context.Context) ([]StatsEntry, error) {
	out, err := c.Run(ctx, "stats", "--no-stream", "--format", "json")
	if err != nil {
		return nil, err
	}
	return decodeList[StatsEntry](out)
}

func (c *CLI) Exec(ctx context.Context, id, command string) (string, error) {
	out, err := c.Run(ctx, "exec", id, command)
	if err != nil {
		return "", err
	}
	return out, nil
}
