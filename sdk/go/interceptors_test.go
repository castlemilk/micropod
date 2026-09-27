package micropod

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"
	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
)

type fakeReq struct{ connect.AnyRequest }

func unaryOK(_ context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
	return nil, nil
}

func unaryErr(code connect.Code) connect.UnaryFunc {
	return func(_ context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		return nil, connect.NewError(code, errors.New(code.String()))
	}
}

func TestRetrySucceedsAfterTransient(t *testing.T) {
	calls := 0
	next := connect.UnaryFunc(func(_ context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		calls++
		if calls < 3 {
			return nil, connect.NewError(connect.CodeUnavailable, errors.New("down"))
		}
		return nil, nil
	})
	wrapped := retryInterceptor{policy: RetryPolicy{
		MaxAttempts:    3,
		InitialBackoff: time.Millisecond,
		MaxBackoff:     5 * time.Millisecond,
		Multiplier:     2,
		RetryableCodes: []connect.Code{connect.CodeUnavailable},
	}}.WrapUnary(next)

	if _, err := wrapped(context.Background(), fakeReq{}); err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if calls != 3 {
		t.Fatalf("expected 3 attempts, got %d", calls)
	}
}

func TestRetryStopsOnNonRetryable(t *testing.T) {
	calls := 0
	next := connect.UnaryFunc(func(_ context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		calls++
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("bad"))
	})
	wrapped := retryInterceptor{policy: RetryPolicy{
		MaxAttempts:    3,
		InitialBackoff: time.Millisecond,
		MaxBackoff:     5 * time.Millisecond,
		Multiplier:     2,
		RetryableCodes: []connect.Code{connect.CodeUnavailable},
	}}.WrapUnary(next)

	if _, err := wrapped(context.Background(), fakeReq{}); err == nil {
		t.Fatal("expected error")
	}
	if calls != 1 {
		t.Fatalf("non-retryable code should not retry, got %d calls", calls)
	}
}

func TestRetryExhaustsAttempts(t *testing.T) {
	calls := 0
	next := connect.UnaryFunc(func(_ context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		calls++
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("down"))
	})
	wrapped := retryInterceptor{policy: RetryPolicy{
		MaxAttempts:    2,
		InitialBackoff: time.Millisecond,
		MaxBackoff:     5 * time.Millisecond,
		Multiplier:     2,
		RetryableCodes: []connect.Code{connect.CodeUnavailable},
	}}.WrapUnary(next)

	if _, err := wrapped(context.Background(), fakeReq{}); err == nil {
		t.Fatal("expected error")
	}
	if calls != 2 {
		t.Fatalf("expected 2 attempts, got %d", calls)
	}
}

func TestRetryHonoursContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	next := connect.UnaryFunc(func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
		cancel() // cancel during the backoff window
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("down"))
	})
	wrapped := retryInterceptor{policy: RetryPolicy{
		MaxAttempts:    5,
		InitialBackoff: time.Hour,
		MaxBackoff:     time.Hour,
		Multiplier:     2,
		RetryableCodes: []connect.Code{connect.CodeUnavailable},
	}}.WrapUnary(next)

	if _, err := wrapped(ctx, fakeReq{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}

func TestTimeoutAppliesDeadline(t *testing.T) {
	var sawDeadline bool
	next := connect.UnaryFunc(func(ctx context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		deadline, ok := ctx.Deadline()
		sawDeadline = ok && time.Until(deadline) <= 50*time.Millisecond
		return nil, nil
	})
	wrapped := timeoutInterceptor{timeout: 50 * time.Millisecond}.WrapUnary(next)
	if _, err := wrapped(context.Background(), fakeReq{}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !sawDeadline {
		t.Fatal("expected a deadline ≤50ms to be set on the outgoing context")
	}
}

func TestTimeoutRespectsEarlierDeadline(t *testing.T) {
	var remaining time.Duration
	next := connect.UnaryFunc(func(ctx context.Context, _ connect.AnyRequest) (connect.AnyResponse, error) {
		deadline, _ := ctx.Deadline()
		remaining = time.Until(deadline)
		return nil, nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	wrapped := timeoutInterceptor{timeout: time.Hour}.WrapUnary(next)
	if _, err := wrapped(ctx, fakeReq{}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if remaining > 50*time.Millisecond {
		t.Fatalf("caller's earlier deadline was widened: %v remaining", remaining)
	}
}

func TestStreamingNotRetried(t *testing.T) {
	calls := 0
	next := connect.StreamingClientFunc(func(_ context.Context, _ connect.Spec) connect.StreamingClientConn {
		calls++
		return nil
	})
	wrapped := retryInterceptor{policy: DefaultRetryPolicy()}.WrapStreamingClient(next)
	wrapped(context.Background(), connect.Spec{})
	wrapped(context.Background(), connect.Spec{})
	if calls != 2 {
		t.Fatalf("streaming interceptor should pass through, got %d calls", calls)
	}
}

var _ = unaryOK // silence unused in case of build-tag drift
var _ = unaryErr(connect.CodeUnknown)

// --- end-to-end tests against a real connect-go server -------------------

// newContainerServer mounts svc on an httptest server and returns its base URL.
func newContainerServer(t *testing.T, svc micropodv1connect.ContainerServiceHandler) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.Handle(micropodv1connect.NewContainerServiceHandler(svc))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

// streamingLogsHandler emits `count` LogChunks spaced `gap` apart.
type streamingLogsHandler struct {
	micropodv1connect.UnimplementedContainerServiceHandler
	count int
	gap   time.Duration
}

func (h *streamingLogsHandler) StreamContainerLogs(ctx context.Context, _ *connect.Request[micropodv1.StreamLogsRequest], stream *connect.ServerStream[micropodv1.LogChunk]) error {
	for i := 0; i < h.count; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(h.gap):
		}
		if err := stream.Send(&micropodv1.LogChunk{Text: "line"}); err != nil {
			return err
		}
	}
	return nil
}

// unavailableGetHandler fails every GetContainer with unavailable and counts calls.
type unavailableGetHandler struct {
	micropodv1connect.UnimplementedContainerServiceHandler
	calls atomic.Int32
}

func (h *unavailableGetHandler) GetContainer(context.Context, *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Container], error) {
	h.calls.Add(1)
	return nil, connect.NewError(connect.CodeUnavailable, errors.New("down"))
}

// contentTypeRecorder records the Content-Type of the last GetContainer request.
type contentTypeRecorder struct {
	micropodv1connect.UnimplementedContainerServiceHandler
	contentType atomic.Pointer[string]
}

func (h *contentTypeRecorder) GetContainer(_ context.Context, req *connect.Request[micropodv1.ContainerRef]) (*connect.Response[micropodv1.Container], error) {
	ct := req.Header().Get("Content-Type")
	h.contentType.Store(&ct)
	return connect.NewResponse(&micropodv1.Container{Id: req.Msg.GetId()}), nil
}

// A server stream must outlive the unary default deadline: 5 chunks at 60ms
// (~300ms) under WithTimeout(100ms) all arrive and the stream ends cleanly.
func TestTimeoutInterceptorDoesNotCancelStreams(t *testing.T) {
	url := newContainerServer(t, &streamingLogsHandler{count: 5, gap: 60 * time.Millisecond})
	client := NewClient(url, WithTimeout(100*time.Millisecond))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stream, err := client.StreamContainerLogs(ctx, connect.NewRequest(&micropodv1.StreamLogsRequest{Id: "c1"}))
	if err != nil {
		t.Fatalf("StreamContainerLogs: %v", err)
	}
	defer stream.Close()

	got := 0
	for stream.Receive() {
		got++
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("stream ended with error after %d chunks: %v", got, err)
	}
	if got != 5 {
		t.Fatalf("expected 5 chunks, got %d", got)
	}
}

func retryPolicyForTests(idempotent func(string) bool) RetryPolicy {
	return RetryPolicy{
		MaxAttempts:    3,
		InitialBackoff: time.Millisecond,
		MaxBackoff:     5 * time.Millisecond,
		Multiplier:     2,
		RetryableCodes: []connect.Code{connect.CodeUnavailable},
		Idempotent:     idempotent,
	}
}

func TestRetrySkipsNonIdempotent(t *testing.T) {
	h := &unavailableGetHandler{}
	url := newContainerServer(t, h)

	var seenProcedure atomic.Pointer[string]
	client := NewClient(url, WithRetry(retryPolicyForTests(func(p string) bool {
		seenProcedure.Store(&p)
		return false
	})))

	_, err := client.GetContainer(context.Background(), connect.NewRequest(&micropodv1.ContainerRef{Id: "c1"}))
	if connect.CodeOf(err) != connect.CodeUnavailable {
		t.Fatalf("expected unavailable, got %v", err)
	}
	if n := h.calls.Load(); n != 1 {
		t.Fatalf("non-idempotent procedure must not be retried, got %d calls", n)
	}
	if p := seenProcedure.Load(); p == nil || *p != micropodv1connect.ContainerServiceGetContainerProcedure {
		t.Fatalf("Idempotent should receive the full procedure name, got %v", p)
	}
}

func TestRetryHonoursIdempotent(t *testing.T) {
	h := &unavailableGetHandler{}
	url := newContainerServer(t, h)
	policy := retryPolicyForTests(func(string) bool { return true })
	client := NewClient(url, WithRetry(policy))

	_, err := client.GetContainer(context.Background(), connect.NewRequest(&micropodv1.ContainerRef{Id: "c1"}))
	if connect.CodeOf(err) != connect.CodeUnavailable {
		t.Fatalf("expected unavailable, got %v", err)
	}
	if n := int(h.calls.Load()); n != policy.MaxAttempts {
		t.Fatalf("idempotent procedure should be retried %d times, got %d calls", policy.MaxAttempts, n)
	}
}

func TestWithConnectOptionsProtoJSON(t *testing.T) {
	h := &contentTypeRecorder{}
	url := newContainerServer(t, h)
	client := NewClient(url, WithConnectOptions(connect.WithProtoJSON()))

	resp, err := client.GetContainer(context.Background(), connect.NewRequest(&micropodv1.ContainerRef{Id: "c1"}))
	if err != nil {
		t.Fatalf("GetContainer: %v", err)
	}
	if resp.Msg.GetId() != "c1" {
		t.Fatalf("unexpected response id %q", resp.Msg.GetId())
	}
	ct := h.contentType.Load()
	if ct == nil || *ct != "application/json" {
		t.Fatalf("expected application/json request Content-Type, got %v", ct)
	}
}
