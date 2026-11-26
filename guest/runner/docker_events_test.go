package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func dockerEventFixture(action string) dockerEvent {
	return dockerEvent{Type: "container", Action: action, Scope: "local", Status: action, ID: "fixture",
		Actor: dockerEventActor{ID: "fixture", Attributes: map[string]string{"name": "example", "image": "alpine"}},
		From:  "alpine"}
}

func TestDockerEventMobyExecActionsAndFilters(t *testing.T) {
	t.Parallel()
	create := dockerExecEventAction("exec_create", []string{"test", "-f", "/tmp/events-ready"})
	if create != "exec_create: test -f /tmp/events-ready" {
		t.Fatalf("unexpected create action %q", create)
	}
	if start := dockerExecEventAction("exec_start", []string{"true"}); start != "exec_start: true " {
		t.Fatalf("unexpected no-argument start action %q", start)
	}
	for _, tc := range []struct {
		action string
		values []string
		match  bool
	}{
		{create, []string{"exec_create"}, true},
		{create, []string{"exec_create: test -f /tmp/events-ready"}, true},
		{create, []string{"exec_create: test"}, false},
		{create, []string{"exec_start", "exec_create: test"}, true},
		{"exec_start: false ", []string{"exec_create", "exec_start"}, true},
		{"exec_die", []string{"exec_die"}, true},
		{"exec_die: synthetic", []string{"exec_die"}, false},
		{"destroy", []string{"des"}, false},
		{"health_status: healthy", []string{"health_status"}, true},
	} {
		if got := matchesDockerEventAction(tc.action, tc.values); got != tc.match {
			t.Errorf("action %q with filters %v matched %v, want %v", tc.action, tc.values, got, tc.match)
		}
	}
}

func TestDockerEventTimeBounds(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		value string
		want  time.Time
	}{
		{"", time.Time{}},
		{"-1", time.Time{}},
		{"0", time.Unix(0, 0)},
		{"12.34", time.Unix(12, 340_000_000)},
		{"12.123456789876", time.Unix(12, 123_456_789)},
		{"1970-01-01T10:00:12.000123+10:00", time.Unix(12, 123_000)},
	} {
		got, err := parseDockerEventTime(tc.value)
		if err != nil || !got.Equal(tc.want) {
			t.Errorf("parse %q = %v, %v, want %v", tc.value, got, err, tc.want)
		}
	}
	for _, value := range []string{"???", "1.", "1.1x", "1.+2", "1.123456789x", "9223372036854775807"} {
		if got, err := parseDockerEventTime(value); err == nil {
			t.Errorf("invalid timestamp %q gave %v", value, got)
		}
	}
	q := dockerEventQuery{since: time.Unix(0, 42), until: time.Unix(0, 44)}
	for ns := int64(41); ns <= 45; ns++ {
		if q.includes(dockerEvent{TimeNano: ns}) != (ns >= 42 && ns <= 44) {
			t.Errorf("bad nanosecond boundary %d", ns)
		}
	}
}

func TestDockerEventRetentionIsBoundedAndOrdered(t *testing.T) {
	t.Parallel()
	var log dockerEventLog
	lagged, err := log.subscribe(false, true)
	if err != nil {
		t.Fatal(err)
	}
	defer log.unsubscribe()
	for n := range dockerEventHistorySize + 12 {
		log.publish(dockerEventFixture(strconv.Itoa(n)))
	}
	if _, ok, notify := log.read(&lagged); ok || notify != nil {
		t.Fatal("lagged client did not terminate")
	}
	cursor, err := log.subscribe(true, false)
	if err != nil {
		t.Fatal(err)
	}
	defer log.unsubscribe()
	log.publish(dockerEventFixture("additional"))
	// The additional event evicts the original replay position. A replay must
	// either deliver its admission window in order or close at the loss.
	if _, ok, notify := log.read(&cursor); ok || notify != nil {
		t.Fatal("lagged replay advanced into a newer admission window")
	}
	cursor, err = log.subscribe(true, false)
	if err != nil {
		t.Fatal(err)
	}
	defer log.unsubscribe()
	for n := 13; n < dockerEventHistorySize+12; n++ {
		event, ok, notify := log.read(&cursor)
		if !ok || notify != nil || event.Action != strconv.Itoa(n) {
			t.Fatalf("history at %d = %+v", n, event)
		}
	}
	if event, ok, _ := log.read(&cursor); !ok || event.Action != "additional" {
		t.Fatalf("last event = %+v", event)
	}
	if _, ok, notify := log.read(&cursor); ok || notify != nil {
		t.Fatal("finite replay did not end")
	}
	payload := strings.Repeat("x", dockerEventHistoryBytes/3)
	for range 5 {
		event := dockerEventFixture("large")
		event.Actor.Attributes["payload"] = payload
		log.publish(event)
	}
	if log.bytes > dockerEventHistoryBytes || log.next-log.first != 2 {
		t.Fatalf("label payload retention used %d bytes across %d events", log.bytes, log.next-log.first)
	}
}

func TestDockerEventAdmissionAndParallelPublish(t *testing.T) {
	t.Parallel()
	var log dockerEventLog
	cursor, err := log.subscribe(true, true)
	if err != nil {
		t.Fatal(err)
	}
	defer log.unsubscribe()
	_, _, changed := log.read(&cursor)
	var workers sync.WaitGroup
	const count = 80
	for n := range count {
		workers.Go(func() { log.publish(dockerEventFixture(strconv.Itoa(n))) })
	}
	workers.Wait()
	select {
	case <-changed:
	default:
		t.Fatal("publication failed to wake subscribed clients")
	}
	seen := make(map[string]bool, count)
	for range count {
		event, ok, _ := log.read(&cursor)
		if !ok || seen[event.Action] || event.TimeNano/1e9 != event.Time {
			t.Fatalf("lost, duplicated, or malformed event %+v", event)
		}
		seen[event.Action] = true
	}
	for i := 1; i < dockerEventStreamLimit; i++ {
		if _, err := log.subscribe(false, true); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := log.subscribe(false, true); !errors.Is(err, errDockerEventStreamLimit) {
		t.Fatalf("excess client = %v", err)
	}
	for i := 1; i < dockerEventStreamLimit; i++ {
		log.unsubscribe()
	}
	if log.subscribers() != 1 {
		t.Fatalf("listeners = %d", log.subscribers())
	}
}

func TestDockerEventUntilReplaysThenCloses(t *testing.T) {
	t.Parallel()
	var log dockerEventLog
	log.publish(dockerEventFixture("create"))
	log.publish(dockerEventFixture("start"))
	for _, until := range []time.Time{time.Now(), time.Now().Add(30 * time.Millisecond)} {
		recorder := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/events", nil).WithContext(t.Context())
		if err := log.serve(recorder, req, dockerEventQuery{until: until}); err != nil {
			t.Fatal(err)
		}
		var actions []string
		read := json.NewDecoder(recorder.Body)
		for {
			var event dockerEvent
			if err := read.Decode(&event); errors.Is(err, io.EOF) {
				break
			} else if err != nil {
				t.Fatal(err)
			}
			actions = append(actions, event.Action)
		}
		if recorder.Code != 200 || !recorder.Flushed || log.subscribers() != 0 || !slices.Equal(actions, []string{"create", "start"}) {
			t.Fatalf("until stream status=%d flushed=%v listeners=%d events=%v", recorder.Code, recorder.Flushed, log.subscribers(), actions)
		}
	}
}

func TestDockerEventStreamReadinessAndHalfClose(t *testing.T) {
	t.Parallel()
	// Use short UDS names on Darwin. The directory is owned and disposable.
	dir, err := os.MkdirTemp("/tmp", "mp-events-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listen := func(name string) *net.UnixListener {
		t.Helper()
		l, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, name), Net: "unix"})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { l.Close() })
		return l
	}
	var log dockerEventLog
	log.publish(dockerEventFixture("before-subscribe"))
	served := make(chan error, 1)
	httpListener := listen("http")
	server := &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		served <- log.serve(w, r, dockerEventQuery{})
	})}
	t.Cleanup(func() { server.Close() })
	go server.Serve(httpListener)
	relay := listen("relay")
	relayDone := make(chan error, 1)
	go func() {
		// Match the raw HVF bridge. EOF from the client becomes CloseWrite
		// on the guest connection while the return stream is still open.
		client, err := relay.AcceptUnix()
		if err != nil {
			relayDone <- err
			return
		}
		defer client.Close()
		upstream, err := net.DialUnix("unix", nil, httpListener.Addr().(*net.UnixAddr))
		if err != nil {
			relayDone <- err
			return
		}
		defer upstream.Close()
		done := make(chan struct{})
		go func() {
			_, _ = io.Copy(upstream, client)
			_ = upstream.CloseWrite()
			close(done)
		}()
		_, _ = io.Copy(client, upstream)
		_ = client.CloseWrite()
		<-done
		relayDone <- nil
	}()
	conn, err := net.DialUnix("unix", nil, relay.Addr().(*net.UnixAddr))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	const limit = 3 * time.Second
	if err := conn.SetDeadline(time.Now().Add(limit)); err != nil {
		t.Fatal(err)
	}
	if _, err := fmt.Fprint(conn, "GET /events HTTP/1.1\r\nHost: docker\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 || response.Header.Get("Content-Type") != "application/json" || log.subscribers() != 1 {
		t.Fatalf("readiness status=%d content=%s listeners=%d", response.StatusCode, response.Header.Get("Content-Type"), log.subscribers())
	}
	log.publish(dockerEventFixture("start"))
	var event dockerEvent
	if err := json.NewDecoder(response.Body).Decode(&event); err != nil || event.Action != "start" || event.Actor.ID != event.ID {
		t.Fatalf("first live event %+v, %v", event, err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-served:
		if err != nil || log.subscribers() != 0 {
			t.Fatalf("closed event stream returned %v with %d listeners", err, log.subscribers())
		}
	case <-time.After(limit):
		t.Fatal("idle event listener survived client disconnect")
	}
	select {
	case err := <-relayDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(limit):
		t.Fatal("half-close relay did not finish after the handler returned")
	}
}
