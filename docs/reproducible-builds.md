# Reproducible Builds

Lattice Linux release binaries are expected to be byte-reproducible from the
tagged source checkout and pinned `Package.resolved`.

To verify the node, coordinator, and worker binaries, run the same Docker-backed check as CI:

```bash
git checkout <release-tag>
scripts/reproducible-build.sh
```

The script archives committed `HEAD`, builds `lattice-node`,
`lattice-mining-coordinator`, and `lattice-miner` in two clean containers from
the immutable `swift@sha256:f5697100d3e66326314fb63a393b1dea2eb694fdcab689b03abc5b50b514ef6e`
image at the same canonical source path, then compares SHA-256 hashes for all
three release artifacts. This is the Swift 6.1.3 Jammy Linux/amd64 manifest
pinned for the release. The script also forces `linux/amd64`, including on
Apple Silicon, and installs Linux dependencies from the immutable
`https://snapshot.ubuntu.com/ubuntu/20260702T024019Z` snapshot. These inputs
change only through an explicit source change. It fixes locale, timezone,
`SOURCE_DATE_EPOCH`, compiler prefix maps, and linker build-ID suppression. It
also strips debug-only metadata from the release copies before hashing. Swift
6.1 emits a `.swift_modhash` compiler metadata section whose bytes can vary
between clean builds even when loadable code/data are identical; the check
removes that non-runtime section before hashing. A mismatch is a
release-blocking failure.

Release archives use the same canonical build flags and normalized binary
copies through `scripts/build-release-binaries.sh`; packaging does not publish
raw `.build/release` outputs. The Linux packaging job stages the committed
source archive at `/workspace/lattice-node` before building, the same source
path used by this gate.

Native macOS/Xcode builds are not part of this reproducibility gate. Docker is
required because Swift 6.1 embeds runtime source paths that are not fully
rewritten by compiler prefix-map flags; building both clean runs at the same
in-container path keeps those paths deterministic.

Set `BUILD_ROOT=/path/to/output` to choose the parent of the fixed
`lattice-node-reproducible` output directory. On macOS/Docker Desktop,
temporary worktrees outside `/Users` default to
`~/Library/Caches/lattice-node/reproducible-builds/...` so Docker can copy the
hash files and normalized artifacts back to the host.
