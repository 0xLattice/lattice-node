#!/usr/bin/env python3
"""Reference mining supervisor: one coordinator batch per block, one
pre-signed reward per block, in nonce order.

Consumes a `lattice-rewards emit-batch` file line by line. The cursor
advances only when a block paying the current line is accepted, or on the
one signature that proves the current nonce is already spent: the node
refuses a template for line `i` (HTTP 400 at template build) while
accepting one for line `i + 1`. Worker failures, node failures, and
transient refusals never advance it — a skipped valid nonce permanently
invalidates every later line — and `i` and `i + 1` both refused means a
gap already exists, so the supervisor stalls loudly instead of cascading
through the rest of the batch.

Children are spawned with a clean signal mask because a shell that forks
with SIGCHLD blocked (nohup + backgrounding) wedges Foundation's child
reaping inside the coordinator. See docs/operations.md.

Configuration (environment):
  NODE_URL      default http://127.0.0.1:8080
  COORDINATOR   default /usr/local/bin/lattice-mining-coordinator
  WORKER        default /usr/local/bin/lattice-miner
  WORKERS       default 1
  BATCH_SIZE    nonces per coordinator batch, default 2000000000
  REWARD_BATCH  default /var/lib/lattice/reward-batch.jsonl
  CURSOR_FILE   default /var/lib/lattice/reward-cursor
  LOG_FILE      default /var/log/lattice-mining.log
  CARRIER_PACE_SECONDS  optional sleep after a carrier round, default 0
                        (an operator damper; the windowed retarget finds the
                        ~target-block-time equilibrium on its own)
"""
import json
import os
import signal
import subprocess
import time
import urllib.error
import urllib.request

NODE_URL = os.environ.get("NODE_URL", "http://127.0.0.1:8080")
COORDINATOR = os.environ.get(
    "COORDINATOR", "/usr/local/bin/lattice-mining-coordinator"
)
WORKER = os.environ.get("WORKER", "/usr/local/bin/lattice-miner")
WORKERS = os.environ.get("WORKERS", "1")
BATCH_SIZE = os.environ.get("BATCH_SIZE", "2000000000")
REWARD_BATCH = os.environ.get(
    "REWARD_BATCH", "/var/lib/lattice/reward-batch.jsonl"
)
CURSOR_FILE = os.environ.get("CURSOR_FILE", "/var/lib/lattice/reward-cursor")
CARRIER_PACE_SECONDS = float(os.environ.get("CARRIER_PACE_SECONDS", "0"))
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/lattice-mining.log")
REWARDS_FILE = CURSOR_FILE + ".current-rewards.json"

signal.pthread_sigmask(signal.SIG_SETMASK, set())
LOG = open(LOG_FILE, "a", buffering=1)


def log(message):
    LOG.write(time.strftime("%FT%T") + " " + message + "\n")


def read_cursor():
    try:
        return int(open(CURSOR_FILE).read().strip())
    except Exception:
        return 0


def write_cursor(index):
    with open(CURSOR_FILE + ".tmp", "w") as handle:
        handle.write(str(index))
    os.replace(CURSOR_FILE + ".tmp", CURSOR_FILE)


def node_healthy():
    try:
        with urllib.request.urlopen(NODE_URL + "/health", timeout=5) as reply:
            return json.load(reply).get("phase") == "active"
    except Exception:
        return False


def template_probe(reward_line):
    """Ask the node to build a template paying `reward_line`.

    Returns "accepted" (it built one), "refused" (HTTP 400 — the reward is
    unusable at the current tip: spent, gapped, or over the allowed amount),
    or "unavailable" for anything that proves nothing about the reward.
    Probe templates are capacity-bounded and expire on their own.
    """
    request = urllib.request.Request(
        NODE_URL + "/v1/mining/templates",
        data=reward_line.encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15):
            return "accepted"
    except urllib.error.HTTPError as error:
        return "refused" if error.code == 400 else "unavailable"
    except Exception:
        return "unavailable"


def current_nonce_is_spent(batch, index):
    """The only signature that justifies advancing without an accepted
    block: line `index` is refused while line `index + 1` builds — the
    chain already contains the current nonce (e.g. a crash between block
    acceptance and the cursor write)."""
    if not node_healthy():
        return False
    if template_probe(batch[index]) != "refused":
        return False
    if index + 1 >= len(batch):
        return False
    return template_probe(batch[index + 1]) == "accepted"


def main():
    batch = [line for line in open(REWARD_BATCH) if line.strip()]
    index = read_cursor()
    refused_streak = 0
    log("supervisor start at reward cursor %d of %d" % (index, len(batch)))
    while True:
        if index >= len(batch):
            log("reward batch exhausted; mining without rewards — re-emit it")
            rewards_args = []
        else:
            with open(REWARDS_FILE, "w") as handle:
                handle.write(batch[index])
            rewards_args = ["--rewards-file", REWARDS_FILE]
        run = subprocess.run(
            [
                COORDINATOR,
                "--node", NODE_URL,
                "--worker-executable", WORKER,
                "--workers", WORKERS,
                "--batch-size", BATCH_SIZE,
                "--once",
            ] + rewards_args,
            capture_output=True,
            text=True,
        )
        result = {}
        for line in reversed((run.stdout or "").strip().splitlines()):
            try:
                result = json.loads(line)
                break
            except Exception:
                continue
        kind = result.get("result", "exit=%d" % run.returncode)
        if kind == "submitted" and result.get("accepted"):
            log("reward %d accepted tip=%s"
                % (index, str(result.get("tipCID", ""))[:24]))
            index += 1
            write_cursor(index)
            refused_streak = 0
            continue
        if kind in ("noSolution", "stale"):
            refused_streak = 0
            continue
        if kind == "submitted" and result.get("disposition") == "carrier":
            # The solution cleared only a child chain's target: the child
            # advances, no parent block was mined, and the reward line is
            # untouched. Routine on a merged-mining chain whose child target
            # is easier than the parent's -- never a refusal signal.
            #
            # Optional operator damper (default off): the windowed retarget
            # converges to the chain's target block time on its own — fast
            # round-bound windows walk the target down until hashing time
            # dominates, then one or two windows settle the equilibrium.
            # Pacing exists for operators who prefer to pin a chain's cadence
            # at an easy target instead of letting difficulty find hashrate.
            refused_streak = 0
            if CARRIER_PACE_SECONDS > 0:
                time.sleep(CARRIER_PACE_SECONDS)
            continue
        if kind in ("workerFailed", "nodeFailed") or kind.startswith("exit="):
            # Worker or coordinator trouble proves nothing about the reward.
            # Retry in place forever; advancing here strands the batch.
            log("reward %d retrying after %s (stderr: %s)"
                % (index, kind, (run.stderr or "")[-200:]))
            time.sleep(5)
            continue
        # backoff: could be a transient node error OR the node refusing the
        # reward. Only the paired probe below is allowed to advance.
        refused_streak += 1
        if refused_streak >= 3 and index < len(batch):
            if current_nonce_is_spent(batch, index):
                log("reward %d already spent on-chain; advancing" % index)
                index += 1
                write_cursor(index)
                refused_streak = 0
                continue
            if (node_healthy()
                    and template_probe(batch[index]) == "refused"):
                # Refused but the next line does not build either: a nonce
                # gap or an over-amount batch. Skipping would only compound
                # the loss — stall loudly until the operator intervenes.
                log("REWARD BATCH STALLED at %d: node refuses this line and "
                    "the next; re-emit the batch (nonce gap or amount over "
                    "the current reward)" % index)
                time.sleep(60)
                continue
        time.sleep(5)


if __name__ == "__main__":
    main()
