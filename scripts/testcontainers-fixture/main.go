// The qualification driver compiles this fixture with ci/samples/go-app's
// unchanged dependency lock, then points the stock client at an explicit socket.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strings"
	"time"

	tc "github.com/testcontainers/testcontainers-go"
	tcexec "github.com/testcontainers/testcontainers-go/exec"
	"github.com/testcontainers/testcontainers-go/wait"
)

const ownerLabel = "io.micropod.qualification.testcontainers"

const serviceScript = `cat >/tmp/tc-response <<'HTTP'
#!/bin/sh
cr=$(printf '\r')
while IFS= read -r -t 2 line && [ "$line" != "$cr" ]; do
    :
done
printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s\n' "$((${#FIXTURE} + 1))" "$FIXTURE"
HTTP
chmod 700 /tmp/tc-response
echo fixture-ready
exec nc -lk -p 8080 -e /tmp/tc-response`

var fixtureName = regexp.MustCompile(`^mp-tc-[a-f0-9]{24}$`)

func emit(event string, fields map[string]any) {
	fields["event"] = event
	_ = json.NewEncoder(os.Stdout).Encode(fields)
}

func request(image, name, owner string) tc.ContainerRequest {
	return tc.ContainerRequest{
		Image: image, Name: name, Labels: map[string]string{ownerLabel: owner},
		Entrypoint: []string{"/bin/sh", "-ec"},
		Cmd:        []string{serviceScript},
		Env:        map[string]string{"FIXTURE": owner}, ExposedPorts: []string{"8080/tcp"},
		WaitingFor: wait.ForAll(wait.ForLog("fixture-ready"), wait.ForListeningPort("8080/tcp"),
			wait.ForHTTP("/ready").WithPort("8080/tcp").WithResponseMatcher(func(body io.Reader) bool {
				data, err := io.ReadAll(io.LimitReader(body, 1024))
				return err == nil && string(data) == owner+"\n"
			})).WithDeadline(12 * time.Second),
	}
}

func open(ctx context.Context, req tc.ContainerRequest, reuse, started bool) (tc.Container, error) {
	c, err := tc.GenericContainer(ctx, tc.GenericContainerRequest{ContainerRequest: req, Reuse: reuse, Started: started})
	if c != nil {
		if err == nil {
			status, inspectErr := c.Inspect(ctx)
			if inspectErr != nil {
				return c, inspectErr
			}
			if status.Config == nil || status.Config.Labels[ownerLabel] != req.Labels[ownerLabel] || status.Name != "/"+req.Name {
				return nil, fmt.Errorf("container %s is outside fixture ownership", c.GetContainerID())
			}
		}
		emit("container", map[string]any{"name": req.Name, "id": c.GetContainerID(), "session": c.SessionID()})
	}
	return c, err
}

func remove(c tc.Container, owner string, result *error) {
	if c == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	status, err := c.Inspect(ctx)
	if err == nil && status.Config != nil && status.Config.Labels[ownerLabel] == owner {
		err = c.Terminate(ctx, tc.StopTimeout(time.Second))
	} else if err == nil {
		err = errors.New("could not verify container ownership for termination")
	}
	if err != nil {
		*result = errors.Join(*result, fmt.Errorf("terminate scoped container: %w", err))
	} else {
		emit("terminated", map[string]any{"id": c.GetContainerID()})
	}
}

func fetch(ctx context.Context, c tc.Container, owner string) error {
	endpoint, err := c.PortEndpoint(ctx, "8080/tcp", "http")
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"/ready", nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1024))
	if err != nil || resp.StatusCode != http.StatusOK || string(data) != owner+"\n" {
		return fmt.Errorf("published HTTP returned %d %q: %v", resp.StatusCode, data, err)
	}
	emit("published-http", map[string]any{"status": resp.StatusCode, "endpoint": endpoint})
	return nil
}

func execText(ctx context.Context, c tc.Container, command ...string) (string, error) {
	code, result, err := c.Exec(ctx, command, tcexec.Multiplexed())
	if err != nil {
		return "", err
	}
	data, err := io.ReadAll(io.LimitReader(result, 2048))
	if code != 0 || err != nil {
		return "", fmt.Errorf("container exec returned %d %q: %v", code, data, err)
	}
	return strings.TrimSuffix(string(data), "\n"), nil
}

func lifecycle(ctx context.Context, image, name string) (err error) {
	req := request(image, name, name)
	first, err := open(ctx, req, true, true)
	defer remove(first, name, &err)
	if err != nil {
		return fmt.Errorf("first stock wait/start: %w", err)
	}
	if err := fetch(ctx, first, name); err != nil {
		return err
	}
	decoy, err := open(ctx, request(image, name+"-other", name), false, false)
	defer remove(decoy, name, &err)
	if err != nil {
		return fmt.Errorf("create prefix decoy: %w", err)
	}

	duplicateCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	second, err := open(duplicateCtx, req, true, true)
	cancel()
	if err != nil {
		return fmt.Errorf("reuse running named container: %w", err)
	}
	if second.GetContainerID() != first.GetContainerID() {
		return errors.New("stock named reuse chose a different container")
	}
	emit("reused-running", map[string]any{"id": second.GetContainerID()})
	if _, err := execText(ctx, first, "/bin/sh", "-ec", `printf '%s\n' "$FIXTURE" >/tmp/tc-writable-marker`); err != nil {
		return fmt.Errorf("write restart marker: %w", err)
	}
	timeout := time.Second
	if err := first.Stop(ctx, &timeout); err != nil {
		return fmt.Errorf("stop test container: %w", err)
	}
	if status, err := first.State(ctx); err != nil || status == nil || status.Running || status.Status != "exited" {
		return fmt.Errorf("expected stopped container after Stop: %v, %v", status, err)
	}
	third, err := open(ctx, req, true, true)
	if err != nil {
		return fmt.Errorf("reuse stopped named container: %w", err)
	}
	if third.GetContainerID() != first.GetContainerID() {
		return errors.New("stopped reuse changed container ID")
	}
	marker, err := execText(ctx, third, "cat", "/tmp/tc-writable-marker")
	if err != nil || marker != name {
		return fmt.Errorf("stopped reuse lost writable marker: %q, %v", marker, err)
	}
	if err := fetch(ctx, third, name); err != nil {
		return err
	}
	emit("reused-stopped", map[string]any{"id": third.GetContainerID(), "marker": marker})
	return nil
}

func networkFixture(ctx context.Context, image, name string, multi bool) (err error) {
	var chosen []string
	first := name + "-network-a"
	second := name + "-network-b"
	for _, suffix := range []string{first, second} {
		network, createErr := tc.GenericNetwork(ctx, tc.GenericNetworkRequest{NetworkRequest: tc.NetworkRequest{
			Name: suffix, Driver: "bridge", Labels: map[string]string{ownerLabel: name},
		}})
		if createErr != nil {
			return fmt.Errorf("create owned bridge %s: %w", suffix, createErr)
		}
		defer func() {
			cleanup, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			if e := network.Remove(cleanup); e != nil {
				err = errors.Join(err, fmt.Errorf("remove owned bridge %s: %w", suffix, e))
			}
		}()
		emit("network", map[string]any{"name": suffix})
		chosen = append(chosen, suffix)
		if !multi {
			break
		}
	}
	req := request(image, name+"-service", name)
	req.Networks = chosen
	req.NetworkAliases = map[string][]string{first: {name + "-alias-a"}, second: {name + "-alias-b"}}
	service, err := open(ctx, req, false, true)
	defer remove(service, name, &err)
	if err != nil {
		return fmt.Errorf("start with stock network request %d: %w", len(chosen), err)
	}
	networks, err := service.Networks(ctx)
	if err != nil {
		return err
	}
	if !slices.Equal(slices.Sorted(slices.Values(networks)), slices.Sorted(slices.Values(chosen))) {
		return fmt.Errorf("network attachments = %v, want %v", networks, chosen)
	}
	for index, net := range chosen {
		peerReq := request(image, fmt.Sprintf("%s-peer-%d", name, index), name)
		peerReq.Networks = []string{net}
		peerReq.ExposedPorts = nil
		peerReq.Cmd = []string{"exec sleep 40"}
		peerReq.WaitingFor = nil
		peer, peerErr := open(ctx, peerReq, false, true)
		defer remove(peer, name, &err)
		if peerErr != nil {
			return peerErr
		}
		alias := req.NetworkAliases[net][0]
		if got, err := execText(ctx, peer, "wget", "-qO-", "http://"+alias+":8080/ready"); err != nil || got != name {
			return fmt.Errorf("owned network %s alias request = %q, %v", net, got, err)
		}
	}
	emit("network-aliases", map[string]any{"networks": chosen})
	return fetch(ctx, service, name)
}

func main() {
	var image, name, mode string
	flag.StringVar(&image, "image", "", "explicit already-present local image")
	flag.StringVar(&name, "name", "", "unique label and object-name prefix")
	flag.StringVar(&mode, "mode", "core", "core, single-network, multi-network or ryuk-abandon")
	flag.Parse()
	if !strings.HasPrefix(os.Getenv("DOCKER_HOST"), "unix:///") || image == "" || !fixtureName.MatchString(name) {
		fmt.Fprintln(os.Stderr, "expected an explicit Unix endpoint, local image, and fixture identity")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	var err error
	switch mode {
	case "core":
		err = lifecycle(ctx, image, name)
	case "single-network", "multi-network":
		err = networkFixture(ctx, image, name, mode == "multi-network")
	case "ryuk-abandon":
		labels := tc.GenericLabels()
		if labels["org.testcontainers.sessionId"] == "" {
			err = errors.New("Ryuk was not enabled")
			break
		}
		emit("session", map[string]any{"id": labels["org.testcontainers.sessionId"]})
		c, startErr := open(ctx, request(image, name, name), false, true)
		if startErr == nil {
			startErr = fetch(ctx, c, name)
		}
		if startErr == nil {
			emit("abandon-ready", map[string]any{"id": c.GetContainerID()})
			input, inputErr := bufio.NewReader(io.LimitReader(os.Stdin, 24)).ReadString('\n')
			if inputErr != nil || input != "exit fixture\n" {
				startErr = errors.New("driver did not release the abandoned fixture")
			}
		}
		// Leaving this owned scope tests cleanup on client process exit.
		err = startErr
	default:
		err = fmt.Errorf("unknown qualification mode %q", mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		emit("result", map[string]any{"passed": false, "error": err.Error()})
		os.Exit(1)
	}
	emit("result", map[string]any{"passed": true})
}
