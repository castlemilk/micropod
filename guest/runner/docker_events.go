package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	dockerEventHistorySize  = 256
	dockerEventHistoryBytes = 8 << 20
	dockerEventStreamLimit  = 64
	dockerEventWriteTimeout = 5 * time.Second
)

var errDockerEventStreamLimit = errors.New("too many active Docker event streams")

type dockerEventActor struct {
	ID         string
	Attributes map[string]string
}

type dockerEvent struct {
	Type     string
	Action   string
	Actor    dockerEventActor
	Scope    string `json:"scope"`
	Time     int64  `json:"time"`
	TimeNano int64  `json:"timeNano"`
	// API versions supported by the native endpoint also carry these fields.
	Status string `json:"status"`
	ID     string `json:"id"`
	From   string `json:"from,omitempty"`
}

type dockerEventQuery struct {
	since, until time.Time
	match        func(dockerEvent) bool
}

func matchesDockerEventAction(action string, values []string) bool {
	if slices.ContainsFunc(values, func(value string) bool {
		return value == "exec_create" || value == "exec_start" || value == "health_status"
	}) {
		return slices.ContainsFunc(values, func(value string) bool { return strings.HasPrefix(action, value) })
	}
	return slices.Contains(values, action)
}

func dockerExecEventAction(action string, cmd []string) string {
	// Docker includes a space after the executable even for an empty argv tail.
	return action + ": " + cmd[0] + " " + strings.Join(cmd[1:], " ")
}

func parseDockerEventTime(value string) (time.Time, error) {
	if value == "" || value == "-1" {
		return time.Time{}, nil
	}
	if timestamp, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return timestamp, nil
	}
	whole, fraction, fractional := strings.Cut(value, ".")
	seconds, err := strconv.ParseInt(whole, 10, 64)
	if err != nil || seconds < -62135596800 || seconds > 253402300799 {
		return time.Time{}, fmt.Errorf("invalid event timestamp %q", value)
	}
	var nanos int64
	if fractional {
		if fraction == "" || strings.ContainsFunc(fraction, func(r rune) bool { return r < '0' || r > '9' }) {
			return time.Time{}, fmt.Errorf("invalid event timestamp %q", value)
		}
		// The Engine API accepts fractional seconds and truncates beyond nanoseconds.
		const zeros = "000000000"
		fraction = fraction[:min(len(fraction), len(zeros))]
		nanos, _ = strconv.ParseInt(fraction+zeros[len(fraction):], 10, 64)
	}
	return time.Unix(seconds, nanos), nil
}

func (q dockerEventQuery) includes(event dockerEvent) bool {
	when := time.Unix(0, event.TimeNano)
	return !when.Before(q.since) && (q.until.IsZero() || !when.After(q.until)) &&
		(q.match == nil || q.match(event))
}

type dockerEventEntry struct {
	event dockerEvent
	bytes int
}

// The event log owns its history and never waits for a client. Each client
// holds a position instead of its own queue. A client that falls behind the
// retained history sees EOF and can reconnect with its last timestamp.
type dockerEventLog struct {
	mu          sync.Mutex
	history     [dockerEventHistorySize]dockerEventEntry
	first, next uint64
	bytes       int
	readers     int
	changed     chan struct{}
}

func (l *dockerEventLog) publish(event dockerEvent) {
	// Account for string payloads and map entries as well as the event itself.
	size := 256 + len(event.Actor.ID) + len(event.From) + len(event.Action)
	for key, value := range event.Actor.Attributes {
		size += 64 + len(key) + len(value)
	}
	if size > dockerEventHistoryBytes {
		return // A single event from a supported create request is below this limit.
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for l.next-l.first == dockerEventHistorySize || l.bytes+size > dockerEventHistoryBytes {
		entry := &l.history[l.first%dockerEventHistorySize]
		l.bytes -= entry.bytes
		*entry = dockerEventEntry{}
		l.first++
	}
	now := time.Now()
	event.Time, event.TimeNano = now.Unix(), now.UnixNano()
	l.history[l.next%dockerEventHistorySize] = dockerEventEntry{event: event, bytes: size}
	l.next++
	l.bytes += size
	if l.changed != nil {
		close(l.changed)
		l.changed = nil
	}
}

type dockerEventCursor struct {
	position, end uint64
	live          bool
}

func (l *dockerEventLog) subscribe(replay, live bool) (dockerEventCursor, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.readers == dockerEventStreamLimit {
		return dockerEventCursor{}, errDockerEventStreamLimit
	}
	l.readers++
	cursor := dockerEventCursor{position: l.next, end: l.next, live: live}
	if replay {
		cursor.position = l.first
	}
	return cursor, nil
}

func (l *dockerEventLog) unsubscribe() {
	l.mu.Lock()
	l.readers--
	l.mu.Unlock()
}

func (l *dockerEventLog) subscribers() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.readers
}

func (l *dockerEventLog) finish(cursor *dockerEventCursor) {
	l.mu.Lock()
	cursor.live = false
	cursor.end = l.next
	l.mu.Unlock()
}

// A nil notification with no event marks the end of a replay or a lagged stream.
func (l *dockerEventLog) read(cursor *dockerEventCursor) (dockerEvent, bool, <-chan struct{}) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if cursor.position < l.first || (!cursor.live && cursor.position == cursor.end) {
		return dockerEvent{}, false, nil
	}
	if cursor.position < l.next {
		event := l.history[cursor.position%dockerEventHistorySize].event
		cursor.position++
		return event, true, nil
	}
	if l.changed == nil {
		l.changed = make(chan struct{})
	}
	return dockerEvent{}, false, l.changed
}

func (l *dockerEventLog) serve(w http.ResponseWriter, r *http.Request, query dockerEventQuery) error {
	live := query.until.IsZero() || time.Now().Before(query.until)
	cursor, err := l.subscribe(!query.since.IsZero() || !query.until.IsZero(), live)
	if err != nil {
		return err
	}
	defer l.unsubscribe()
	var until <-chan time.Time
	if live && !query.until.IsZero() {
		timer := time.NewTimer(time.Until(query.until))
		defer timer.Stop()
		until = timer.C
	}
	controller := http.NewResponseController(w)
	deadline := func() {
		// HTTP transports may acknowledge a write that then stalls in the relay.
		// An idle stream remains open and gets a fresh deadline on the next write.
		_ = controller.SetWriteDeadline(time.Now().Add(dockerEventWriteTimeout))
	}
	// Bound the terminating chunk too. Keeping this streaming connection out
	// of the pool also lets the relay's two halves complete on a finite replay.
	defer deadline()
	deadline()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	w.WriteHeader(http.StatusOK)
	if err := controller.Flush(); err != nil {
		return nil
	}
	encoder := json.NewEncoder(w)
	for {
		select {
		case <-r.Context().Done():
			return nil
		case <-until:
			l.finish(&cursor)
			until = nil
		default:
		}
		event, ok, changed := l.read(&cursor)
		if ok {
			if query.includes(event) {
				deadline()
				if err := encoder.Encode(event); err != nil {
					return nil
				}
				if err := controller.Flush(); err != nil {
					return nil
				}
			}
			continue
		}
		if changed == nil {
			return nil
		}
		select {
		case <-r.Context().Done():
			return nil
		case <-until:
			l.finish(&cursor)
			until = nil
		case <-changed:
		}
	}
}
