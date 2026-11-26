"""Validate ordinal-paired observations from the opt-in read-size diagnostic client."""
import math

CLIENT_SHA256 = "3c3c3090ccef15a693df7d49facfb366bddd49daa61df1eafdaadfde358e4328"


def summarize(client):
    count = client["arrivals"]
    rows = client["fresh_samples"]
    if count != 240 or client["period_us"] != 25000 or not isinstance(rows, list) or len(rows) != count:
        raise ValueError("expected the complete 240-arrival schedule")
    begin, end = client["begin_ns"], client["end_ns"]
    if (type(begin) is not int or type(end) is not int or not 0 < begin < end
            or not math.isclose(end - begin, client["window_s"] * 1e9, rel_tol=0, abs_tol=1)
            or end - begin < 6_000_000_000):
        raise ValueError("score endpoints disagree with the bulk clock")
    scheduled, launched, after_launch = [], [], []
    for i, row in enumerate(rows):
        ordinal, target, start, finish = (row[k] for k in ("ordinal", "scheduled_ns", "launch_delay_ns", "completion_delay_ns"))
        if (any(type(v) is not int for v in (ordinal, target, start, finish)) or type(row["ok"]) is not bool
                or ordinal != i or target != i * 25_000_000 or not 0 <= start <= finish):
            raise ValueError("fresh request identity or event timing mismatch")
        launched.append(start // 1000)
        # The original summaries leave zero in a failed request's timing slot.
        scheduled.append(finish // 1000 if row["ok"] else 0)
        if row["ok"]:
            after_launch.append(finish - start)
    scheduled.sort()
    launched.sort()
    for key, value in (("fresh_p50_us", scheduled[119]), ("fresh_p95_us", scheduled[227]),
                       ("fresh_p99_us", scheduled[237]), ("dispatch_p95_us", launched[227]),
                       ("dispatch_max_us", launched[-1])):
        if type(client[key]) is not int or client[key] != value:
            raise ValueError("paired observations disagree with " + key)
    if len(rows) - len(after_launch) > len(client.get("errors") or []):
        raise ValueError("missing error evidence for a failed fresh observation")
    after_launch.sort()
    n = len(after_launch)
    return dict(offered=count, succeeded=n, failed=count - n,
                success_post_launch_p95_ns=after_launch[math.ceil(.95 * n) - 1] if n else None,
                success_post_launch_p99_ns=after_launch[math.ceil(.99 * n) - 1] if n else None)
