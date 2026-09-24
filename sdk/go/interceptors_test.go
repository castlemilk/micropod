package micropod

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"
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
