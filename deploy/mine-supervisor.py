#!/usr/bin/env python3
"""Reference mining supervisor: one coordinator batch per round.

Each block pays the recipient configured for its chain (the block's
`rewardRecipient`, which the proof of work covers); a chain with no
recipient burns its reward and fees. No key lives on the mining host and no
reward line or cursor is kept: a recipient is only an address.

Children are spawned with a clean signal mask because a shell that forks
with SIGCHLD blocked (nohup + backgrounding) wedges Foundation's child
reaping inside the coordinator. See docs/operations.md.

Configuration (environment):
  NODE_URL      default http://127.0.0.1:8080
  COOKIE_FILE   the node's loopback RPC cookie, default
                ~/.lattice/chains/Nexus/.cookie (lattice-node's default
                data directory); `lattice up --root R` writes R/chains/Nexus/.cookie
  COORDINATOR   default /usr/local/bin/lattice-mining-coordinator
  WORKER        default /usr/local/bin/lattice-miner
  WORKERS       default 1
  BATCH_SIZE    nonces per coordinator batch, default 2000000000
  RECIPIENTS    comma-separated <chain path>=<address> entries, e.g.
                "Nexus=bafy...,Nexus/Payments=bafy..."; default none
                (every chain burns its reward and fees)
  LOG_FILE      default /var/log/lattice-mining.log
  CARRIER_PACE_SECONDS  optional sleep after a carrier round, default 0
                        (an operator damper; the retarget finds the
                        ~target-block-time equilibrium on its own)
"""
import json
import os
import signal
import subprocess
import sys
import time

# The signed reward batch and its cursor are gone. A host still configured
# for them would otherwise mine with no recipient and burn every reward.
for retired in ("REWARD_BATCH", "CURSOR_FILE"):
    if retired in os.environ:
        sys.exit(
            "%s is no longer supported: reward batches were replaced by "
            "RECIPIENTS (<chain path>=<address>, comma-separated); unset %s "
            "and set RECIPIENTS" % (retired, retired)
        )

NODE_URL = os.environ.get("NODE_URL", "http://127.0.0.1:8080")
COOKIE_FILE = os.path.expanduser(
    os.environ.get("COOKIE_FILE", "~/.lattice/chains/Nexus/.cookie")
)
COORDINATOR = os.environ.get(
    "COORDINATOR", "/usr/local/bin/lattice-mining-coordinator"
)
WORKER = os.environ.get("WORKER", "/usr/local/bin/lattice-miner")
WORKERS = os.environ.get("WORKERS", "1")
BATCH_SIZE = os.environ.get("BATCH_SIZE", "2000000000")
RECIPIENTS = [
    entry.strip()
    for entry in os.environ.get("RECIPIENTS", "").split(",")
    if entry.strip()
]
CARRIER_PACE_SECONDS = float(os.environ.get("CARRIER_PACE_SECONDS", "0"))
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/lattice-mining.log")

signal.pthread_sigmask(signal.SIG_SETMASK, set())
LOG = open(LOG_FILE, "a", buffering=1)


def log(message):
    LOG.write(time.strftime("%FT%T") + " " + message + "\n")


def main():
    recipient_args = []
    for entry in RECIPIENTS:
        recipient_args += ["--recipient", entry]
    log("supervisor start; recipients: %s"
        % (", ".join(RECIPIENTS) or "none (rewards and fees burn)"))
    while True:
        run = subprocess.run(
            [
                COORDINATOR,
                "--node", NODE_URL,
                "--rpc-cookie-file", COOKIE_FILE,
                "--worker-executable", WORKER,
                "--workers", WORKERS,
                "--batch-size", BATCH_SIZE,
                "--once",
            ] + recipient_args,
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
        log("round: %s %s" % (kind, result.get("disposition")))
        if kind == "submitted" and result.get("accepted"):
            log("accepted tip=%s" % str(result.get("tipCID", ""))[:24])
            continue
        if kind in ("noSolution", "stale"):
            continue
        if kind == "submitted" and result.get("disposition") == "carrier":
            # The solution cleared only a child chain's target: the child
            # advances and no parent block was mined. Routine on a
            # merged-mining chain whose child target is easier than the
            # parent's.
            #
            # Optional operator damper (default off): pacing exists for
            # operators who prefer to pin a chain's cadence at an easy target
            # instead of letting difficulty find hashrate.
            if CARRIER_PACE_SECONDS > 0:
                time.sleep(CARRIER_PACE_SECONDS)
            continue
        if kind in ("workerFailed", "nodeFailed") or kind.startswith("exit="):
            log("retrying after %s (stderr: %s)"
                % (kind, (run.stderr or "")[-200:]))
        time.sleep(5)


if __name__ == "__main__":
    main()
