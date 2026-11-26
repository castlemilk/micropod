"""Time content and namespace visibility through a second local process.

The two existing parent directories may be aliases or locally accessible source
and synchronized view roots. Each run owns one fresh child on the writer side.
The reader only opens files beneath the matching child of its supplied root.
Run in the opposite direction by swapping the two roots. A same-host capture
does not exercise a reader inside a guest.
"""
import argparse
import hashlib
import json
import math
import multiprocessing
import os
from pathlib import Path
import secrets
import tempfile
import time


NAMES = ("draft", "renamed")
ACTIONS = ("create", "atomic_replace", "rename", "delete")
POLL_SECONDS = 0.001
BYTES = 4096


def states(marker, round_number):
    original, modified = (hashlib.shake_256(marker + f"/{round_number}/{version}".encode()).digest(BYTES)
                          for version in ("original", "modified"))
    return ((original, None), (modified, None), (None, modified), (None, None))


def same_fixture(root, marker):
    try:
        with (root / "identity").open("rb") as f:
            return f.read(len(marker) + 1) == marker
    except FileNotFoundError:
        return False


def matches(root, marker, expected):
    if not same_fixture(root, marker):
        return False
    for name, wanted in zip(NAMES, expected):
        try:
            with (root / name).open("rb") as f:
                if wanted is None or f.read(BYTES + 1) != wanted:
                    return False
        except FileNotFoundError:
            if wanted is not None:
                return False
    # Losing the fixture during the two negative lookups is not a successful delete.
    return expected != (None, None) or same_fixture(root, marker)


def wait_for_state(root, marker, expected, timeout):
    deadline = time.monotonic() + timeout
    while not matches(root, marker, expected):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("reader timed out waiting for fixture identity, file bytes or names")
        time.sleep(min(remaining, POLL_SECONDS))


def observe(root, marker, rounds, timeout, sender):
    with sender:
        try:
            wait_for_state(root, marker, (None, None), timeout)
            for number in range(1, rounds + 1):
                for action, expected in zip(ACTIONS, states(marker, number)):
                    sender.send(("armed", number, action))
                    wait_for_state(root, marker, expected, timeout)
                    sender.send(("observed", number, action))
        except (OSError, ValueError) as exc:
            sender.send(("error", str(exc)))


def receive(reader, expected, timeout):
    if not reader.poll(timeout):
        raise TimeoutError(f"timed out waiting for reader to report {expected}")
    try:
        result = reader.recv()
    except EOFError as exc:
        raise RuntimeError("reader exited before reporting the observation") from exc
    if result[0] == "error":
        raise RuntimeError(result[1])
    if result != expected:
        raise RuntimeError(f"unexpected reader response {result}")


def apply(root, action, contents):
    draft, renamed = (root / name for name in NAMES)
    if action == "create":
        with draft.open("xb") as f:
            f.write(contents[0])
    elif action == "atomic_replace":
        staged = root / "editor-save"
        with staged.open("xb") as f:
            f.write(contents[0])
        os.replace(staged, draft)
    elif action == "rename":
        draft.rename(renamed)
    elif action == "delete":
        renamed.unlink()


def measure(writer_root=None, reader_root=None, rounds=8, timeout=5.0):
    if type(rounds) is not int or not 1 <= rounds <= 64 or not (0.1 <= timeout <= 30):
        raise ValueError("supply 1–64 rounds and a 0.1–30 second observation timeout")
    writer_root = Path(writer_root or tempfile.gettempdir()).absolute()
    reader_root = Path(reader_root or writer_root).absolute()
    if not (writer_root.is_dir() and reader_root.is_dir()):
        raise ValueError("both parent directories must exist")
    samples = []
    marker = secrets.token_hex(24).encode()
    ctx = multiprocessing.get_context("spawn")
    with tempfile.TemporaryDirectory(dir=writer_root, prefix="micropod-edit-") as owned:
        root = Path(owned)
        (root / "identity").write_bytes(marker)
        receiver, sender = ctx.Pipe(duplex=False)
        reader = ctx.Process(target=observe, args=(reader_root / root.name, marker, rounds, timeout, sender))
        with receiver, sender:
            reader.start()
            sender.close()
            try:
                for number in range(1, rounds + 1):
                    for action, contents in zip(ACTIONS, states(marker, number)):
                        # Exclude interpreter startup from the first edit sample.
                        receive(receiver, ("armed", number, action), timeout + 3)
                        start = time.monotonic_ns()
                        apply(root, action, contents)
                        written = time.monotonic_ns()
                        receive(receiver, ("observed", number, action), timeout)
                        acknowledged = time.monotonic_ns()
                        samples.append({"round": number, "action": action, "mutation_ns": written - start,
                                        "start_to_reader_ack_ns": acknowledged - start,
                                        "mutation_return_to_reader_ack_ns": acknowledged - written})
                reader.join(2)
                if reader.exitcode != 0:
                    raise RuntimeError(f"reader did not exit cleanly: {reader.exitcode}")
            finally:
                if reader.is_alive():
                    reader.kill()
                reader.join(2)
                reader_pid = reader.pid
                reader.close()
    summary = {}
    ranks = {f"p{q}": math.ceil(q * rounds / 100) for q in (50, 95, 99)}
    for action in ACTIONS:
        values = sorted(s["start_to_reader_ack_ns"] for s in samples if s["action"] == action)
        summary[action] = {f"{label}_ns": values[rank - 1] for label, rank in ranks.items()}
    return {"workload": "micropod-edit-visibility-v1", "writer_pid": os.getpid(), "reader_pid": reader_pid,
            "writer_parent": str(writer_root), "reader_parent": str(reader_root), "rounds": rounds,
            "payload_bytes": BYTES, "reader_poll_interval_s": POLL_SECONDS, "observation_timeout_s": timeout,
            "timing": "writer monotonic start through reader acknowledgement, including polling, scheduling and IPC",
            "percentiles": {"method": "nearest rank", "samples_per_action": rounds, "one_based_ranks": ranks,
                            "at_sample_maximum": [label for label, rank in ranks.items() if rank == rounds]},
            "start_to_reader_ack": summary, "samples": samples}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--writer-root", type=Path, help="existing writer-side parent, default system temp")
    parser.add_argument("--reader-root", type=Path, help="existing reader-side parent, default writer parent")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=5.0, help="maximum seconds per observation")
    options = parser.parse_args()
    try:
        print(json.dumps(measure(options.writer_root, options.reader_root, options.rounds, options.timeout), indent=2))
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"Edit observation failed: {error}\n")
