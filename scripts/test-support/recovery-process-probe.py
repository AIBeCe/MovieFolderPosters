#!/usr/bin/env python3
"""Qualify crash lock release and stale-instance fencing in an isolated directory."""

from pathlib import Path
import select
import subprocess
import sys
import tempfile


def run_probe(executable, command, directory):
    """Require one bounded child invocation to observe the expected durable state."""
    subprocess.run([executable, command, str(directory)], check=True, timeout=10)


def start_waiting_probe(executable, command, directory):
    """Wait for explicit child readiness rather than guessing a scheduling delay."""
    process = subprocess.Popen(
        [executable, command, str(directory)], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )
    try:
        readable, _, _ = select.select([process.stdout], [], [], 10)
        if not readable or process.stdout.readline() != b"ready\n":
            raise AssertionError(f"{command} did not establish its checkpoint")
        return process
    except BaseException:
        stop_probe(process)
        raise


def stop_probe(process):
    """Release every child even when an assertion fails."""
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)
    process.stdin.close()
    process.stdout.close()


def main():
    """Exercise real process death and an instance constructed before mode activation."""
    executable = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="MovieFolderPosters-RecoveryProcess-") as temporary:
        directory = Path(temporary) / "Recovery"
        holder = start_waiting_probe(executable, "hold", directory)
        try:
            run_probe(executable, "busy", directory)
            holder.kill()
            assert holder.wait(timeout=10) == -9, "writer did not die at the retained-lease checkpoint"
        finally:
            stop_probe(holder)
        run_probe(executable, "enable", directory)
        run_probe(executable, "blocked", directory)
        run_probe(executable, "disable", directory)
        stale = start_waiting_probe(executable, "stale", directory)
        try:
            run_probe(executable, "enable", directory)
            stale.stdin.write(b"1")
            stale.stdin.flush()
            assert stale.wait(timeout=10) == 0, "cached service bypassed newly enabled recovery mode"
        finally:
            stop_probe(stale)
        run_probe(executable, "disable", directory)
        run_probe(executable, "allowed", directory)
    print("PASS: killed-writer lock release, durable mode, stale-process fence, and explicit resume")


if __name__ == "__main__":
    main()
