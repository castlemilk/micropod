"""Observe host idle before launching a measured client."""
import math
import time


IDLE_FLOOR = 90
MAX_PAIRED_GAP = 5


class IdleTimeout(ValueError):
    """The pre-client idle window never qualified within its time budget."""


def valid_pct(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 100


def record_idle(row, previous, idle, diagnostic):
    """Apply the original single-interval admission rules."""
    if not valid_pct(idle):
        raise ValueError("invalid host idle observation")
    gap = None if previous is None else abs(idle - previous)
    row.update(idle_pct=idle, paired_idle_gap_pp=gap,
               idle_gate_passed=idle >= IDLE_FLOOR and (gap is None or gap <= MAX_PAIRED_GAP))
    if not diagnostic:
        if idle < IDLE_FLOOR:
            raise ValueError("host idle below 90 percent")
        if gap is not None and gap > MAX_PAIRED_GAP:
            raise ValueError("paired host idle differs by more than five percentage points")


def await_idle(row, previous, diagnostic, wait_seconds, sample, guard, publish, *,
               clock=time.monotonic, sleep=time.sleep):
    """Wait only before a timed invocation. publish() persists the caller's current row."""
    if type(wait_seconds) not in (int, float) or not math.isfinite(wait_seconds) or wait_seconds < 0:
        raise ValueError("idle wait must be a finite nonnegative number of seconds")
    if previous is not None and not valid_pct(previous):
        raise ValueError("invalid previous host idle observation")
    start = clock()
    deadline = start + wait_seconds
    wait = wait_seconds > 0 and not diagnostic
    observations = row["idle_observations"] = []
    streak = 0
    last_progress = None
    label = " ".join(str(row[k]) for k in ("phase", "arm") if k in row)
    prefix = f"[idle] {label}".rstrip()
    while not observations or clock() < deadline:
        guard()
        if observations and clock() >= deadline:
            break
        idle = sample()
        elapsed = clock() - start
        try:
            record_idle(row, previous, idle, diagnostic=True)
        except ValueError:
            observations.append({"elapsed_seconds": elapsed, "idle_pct": None, "eligible": False,
                                 "error": "invalid host idle observation"})
            publish()
            raise
        eligible = row["idle_gate_passed"]
        streak = streak + 1 if eligible else 0
        gap = row["paired_idle_gap_pp"]
        observations.append({"elapsed_seconds": elapsed, "idle_pct": idle,
                             "paired_idle_gap_pp": gap, "eligible": eligible})
        if wait:
            row["idle_gate_passed"] = streak >= 2 and elapsed <= wait_seconds
        publish()
        if not wait:
            record_idle(row, previous, idle, diagnostic)
            return idle
        if last_progress is None or elapsed - last_progress >= 15 or row["idle_gate_passed"]:
            state = "ready" if row["idle_gate_passed"] else "waiting"
            gap_info = "" if gap is None else f", paired gap {gap:.2f}/{MAX_PAIRED_GAP} pp"
            print(f"{prefix} {state} at {elapsed:.1f}s, {idle:.2f}% idle (floor {IDLE_FLOOR}%{gap_info}), "
                  f"{streak}/2 consecutive eligible", flush=True)
            last_progress = elapsed
        if row["idle_gate_passed"]:
            return idle
        remaining = deadline - clock()
        if remaining <= 0:
            break
        sleep(min(1, remaining))

    gap_text = "unpaired" if gap is None else f"{gap:.2f} pp"
    message = (f"host idle admission timed out after {clock() - start:.2f}s "
               f"({len(observations)} observations, {streak}/2 consecutive eligible, "
               f"last {idle:.2f}%, floor {IDLE_FLOOR}%, paired gap {gap_text}, limit {MAX_PAIRED_GAP} pp)")
    print(f"{prefix} {message}", flush=True)
    raise IdleTimeout(message)
