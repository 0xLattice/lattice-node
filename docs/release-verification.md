# Release Verification

Lattice Node release archives are published with four operator-verifiable artifacts:

- `*.tar.gz`: release binaries for `lattice-node`, `lattice-mining-coordinator`, and `lattice-miner`.
- `*.tar.gz.sha256`: SHA-256 checksum for the archive.
- `*.spdx.json`: SBOM generated from `Package.resolved`.
- `*.artifacts.json`: portable manifest binding the archive name, checksum, archive digest, and SBOM digest. Its paths are file names relative to the manifest, so keep all four assets together after download.

For tagged releases, CI also publishes signed GitHub artifact attestations for the archive provenance and SBOM. Operators can verify a release with:

```sh
shasum -a 256 -c lattice-node-<version>-<platform>.tar.gz.sha256
gh attestation verify lattice-node-<version>-<platform>.tar.gz --repo adalinxx/lattice-node
gh attestation verify lattice-node-<version>-<platform>.tar.gz --repo adalinxx/lattice-node --predicate-type https://spdx.dev/Document/v2.3

# From a lattice-node checkout, with all four release assets in one directory:
.github/scripts/check-release-artifact-bindings.sh \
  /path/to/lattice-node-<version>-<platform>.artifacts.json
```

Before packaging each platform archive, the release workflow runs the test
suite. During bundle assembly, the smoke test exercises the bundle's node,
`lattice-mining-coordinator`, and `lattice-miner` together. After archive
assembly, the workflow extracts that archive and reruns the multichain daemon
E2E suite against its `lattice-node`. Linux release binaries statically include
the Swift runtime and are also executed in a plain Ubuntu container without a
Swift toolchain. Linux hosts still need the standard system libraries used by
the executables: libatomic, libcurl, libsqlite3, and libxml2. The smoke test
verifies the exact Nexus genesis, mines one canonical block through the external
mining pipeline, then restarts the node and verifies the same persisted tip.

The provenance attestation binds the archive artifact's name and digest to the GitHub workflow identity for `adalinxx/lattice-node`. The SBOM attestation binds that same archive artifact to the SPDX dependency inventory generated during the same workflow run. The checksum catches transfer corruption; the manifest records the archive name, checksum subject name, archive digest, and SBOM digest for the sibling release assets.

The publishing job treats tagged releases as immutable: it fails rather than replacing assets on an existing release.
Repository administrators should also protect the release tag patterns from force-updates and deletion. The workflow verifies the tag target immediately before publishing, but only repository policy can prevent a privileged actor from moving it afterward.
