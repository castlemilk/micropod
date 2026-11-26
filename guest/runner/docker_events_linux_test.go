package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestDockerEventsRouteFiltersComposeActorHistory(t *testing.T) {
	engine := &dockerEngine{}
	label := "com.docker.compose.project"
	first := &dockerContainer{dockerRecord: dockerRecord{
		ID: "28bac33ee499", Name: "fixture-app-1",
		Config: dockerConfig{Image: "alpine:3.23", Labels: map[string]string{label: "fixture", "com.docker.compose.service": "app"}},
	}}
	engine.containerEvent(first, "create", nil)
	engine.containerEvent(first, "start", nil)
	first.Config.Labels[label] = "unrelated"
	engine.containerEvent(first, "start", nil)
	for _, filter := range []string{
		`{"type":["container"],"container":["other","28ba"],"event":["start"],"label":["com.docker.compose.project=fixture","com.docker.compose.service"],"scope":["local"],"image":["alpine"]}`,
		`{"type":{"container":true,"image":false},"container":{"fixture-app":true},"event":{"start":true},"label":{"com.docker.compose.project=fixture":true}}`,
	} {
		query := url.Values{"filters": {filter}, "until": {time.Now().UTC().Format(time.RFC3339Nano)}}
		w := httptest.NewRecorder()
		engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/events?"+query.Encode(), nil))
		decoder := json.NewDecoder(w.Body)
		var event dockerEvent
		if err := decoder.Decode(&event); err != nil || w.Code != 200 {
			t.Fatalf("filtered events returned status %d, %v", w.Code, err)
		}
		if event.Type != "container" || event.Scope != "local" || event.Action != "start" || event.Status != "start" ||
			event.Actor.ID != first.ID || event.ID != first.ID || event.From != "alpine:3.23" ||
			event.Actor.Attributes["name"] != first.Name || event.Actor.Attributes[label] != "fixture" ||
			event.TimeNano == 0 || event.TimeNano/1e9 != event.Time {
			t.Fatalf("invalid container event: %+v", event)
		}
		if err := decoder.Decode(&event); !errors.Is(err, io.EOF) {
			t.Fatalf("filtered stream did not close after one matching event: %v", err)
		}
	}
	for _, path := range []string{"?since=bad", "?until=bad", "?since=20&until=10", "?filters=invalid", "?filters=%zz"} {
		w := httptest.NewRecorder()
		engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/events"+path, nil))
		if w.Code != 400 || engine.events.subscribers() != 0 {
			t.Fatalf("invalid query %s returned %d with %d subscribers", path, w.Code, engine.events.subscribers())
		}
	}
	if _, err := engine.events.subscribe(false, true); err != nil {
		t.Fatal(err)
	}
	defer engine.events.unsubscribe()
	w := httptest.NewRecorder()
	engine.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1.47/info", nil))
	var info struct{ NEventsListener int }
	if err := json.Unmarshal(w.Body.Bytes(), &info); err != nil || info.NEventsListener != 1 {
		t.Fatalf("/info listeners = %+v, %v", info, err)
	}
}

func TestDockerKillPublishesOnlyAnAcknowledgedRequest(t *testing.T) {
	for _, rpcErr := range []error{nil, errors.New("CRI failed to kill")} {
		name := "acknowledged"
		if rpcErr != nil {
			name = "failed"
		}
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			requested, acknowledge := make(chan struct{}), make(chan struct{})
			runtime := dockerStopRuntime{stop: func(ctx context.Context, req *cri.StopContainerRequest) (*cri.StopContainerResponse, error) {
				if req.ContainerId != "runtime-id" || req.Timeout != 0 {
					return nil, errors.New("kill did not target the correct process and grace")
				}
				close(requested)
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case <-acknowledge:
					return &cri.StopContainerResponse{}, rpcErr
				}
			}}
			engine := &dockerEngine{node: node{runtime: runtime}}
			c := &dockerContainer{dockerRecord: dockerRecord{ID: "docker-id", Phase: "running", RuntimeID: "runtime-id"}, changed: make(chan struct{})}
			cursor, err := engine.events.subscribe(false, true)
			if err != nil {
				t.Fatal(err)
			}
			defer engine.events.unsubscribe()
			done := make(chan error, 1)
			go func() { done <- engine.stop(ctx, c, 0, "kill") }()
			select {
			case <-requested:
			case err := <-done:
				t.Fatalf("no kill request reached CRI: %v", err)
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			engine.mu.Lock()
			ack := c.killEventDone
			engine.mu.Unlock()
			if ack == nil {
				t.Fatal("exit acknowledgement was missing during kill")
			}
			if event, ok, _ := engine.events.read(&cursor); ok {
				t.Fatalf("kill event escaped before CRI acknowledged it: %+v", event)
			}
			close(acknowledge)
			select {
			case <-ack:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			event, exists, _ := engine.events.read(&cursor)
			if rpcErr == nil {
				if !exists || event.Action != "kill" || event.Actor.Attributes["signal"] != "9" {
					t.Fatalf("kill acknowledgement did not first publish event: %+v", event)
				}
				engine.mu.Lock()
				c.Exits++
				c.Phase, c.RuntimeID = "exited", ""
				c.signal()
				engine.mu.Unlock()
			} else if exists {
				t.Fatalf("failed kill produced a lifecycle event: %+v", event)
			}
			select {
			case err := <-done:
				if !errors.Is(err, rpcErr) {
					t.Fatalf("kill returned %v, want %v", err, rpcErr)
				}
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
		})
	}
}
