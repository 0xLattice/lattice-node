#!/bin/sh
# Container entrypoint for the one-chain node and external mining binaries.
#
#   docker run <image> --flags...                        -> lattice-node
#   docker run <image> lattice-node --flags...           -> lattice-node
#   docker run <image> lattice-mining-coordinator ...    -> coordinator
#   docker run <image> lattice-miner ...                 -> worker
#
# Bare args (no leading binary name) default to lattice-node so existing
# `docker run <image> --listen-port 4001 ...`-style call sites keep working.
case "$1" in
  lattice-node) shift; exec lattice-node "$@" ;;
  lattice-mining-coordinator) shift; exec lattice-mining-coordinator "$@" ;;
  lattice-miner) shift; exec lattice-miner "$@" ;;
  *) exec lattice-node "$@" ;;
esac
