#!/bin/sh
# Container entrypoint for the one-process hosted tree.
#
#   docker run <image> --flags...                        -> lattice-node
#   docker run <image> lattice-node --flags...           -> lattice-node
#   docker run <image> lattice up ...                    -> operator CLI
#
# Bare args (no leading binary name) default to lattice-node so existing
# `docker run <image> --listen-port 4001 ...`-style call sites keep working.
case "$1" in
  lattice) shift; exec lattice "$@" ;;
  lattice-node) shift; exec lattice-node "$@" ;;
  *) exec lattice-node "$@" ;;
esac
