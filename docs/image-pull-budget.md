# Image pull retry budget v1

Standalone `ImageService.pull` owns its existing three-attempt policy. Connect
`PullImage` and REST `POST /v1/images/pull` use `pullForAPI`: at most one CLI pull
per request, with no platform widening or internal backoff. A headerless API
request also makes at most one CLI pull and cannot grant caller retry permission.

A caller can coordinate up to three attempts with these four HTTP headers:

| Header | Value |
| --- | --- |
| `Micropod-Pull-Budget-Owner` | `caller` |
| `Micropod-Pull-Attempt` | Current attempt, starting at 1 |
| `Micropod-Pull-Max-Attempts` | Total attempt limit, from 1 through 3 |
| `Micropod-Pull-Deadline-Unix-Ms` | One absolute deadline shared by every attempt |

All four headers must be present together. Invalid or partial budgets fail before
the CLI starts. An already expired budget reports `deadline` with zero attempts;
expiry during a pull cancels that request's CLI stream. The API does not extend
the deadline or start another attempt.

The redacted `image_pull_v1` terminal receipt includes `budgetOwner`, `attempts`,
`callerAttempt`, `maximumTotalAttempts`, `deadlineUnixMilliseconds` and
`retryBudgetExhausted`. `attempts` counts this request's CLI attempts, while
`callerAttempt` identifies the request within the caller's acquisition. A retry
requires a completed ordinary fetch failure, a supported transient category,
untruncated evidence and remaining caller budget. The final permitted attempt
always reports `retryAllowed: false`. Transport cancellation, signals, stalls,
authentication, storage, TLS, rate limiting and unknown failures cannot grant a
retry. A response can arrive after the acquisition deadline; the caller must
still enforce its own unchanged deadline and verify every echoed budget field.

This matches Cuttlefish's caller-owned receipt contract at
`e233bf898f2f8aeb8c2c3723323457eae0d3f8c0`. No proto or generated SDK changes are
needed. Existing callers that do not acknowledge this contract must fail closed
instead of interpreting progress text as retry permission.

The headers coordinate a caller's budget; they are not a durable operation
ledger and do not deduplicate repeated requests. An ambiguous transport failure
does not acknowledge a completed attempt and must not grant another request.
