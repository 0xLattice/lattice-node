#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

version="${RELEASE_VERSION:-${1:-$(git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD)}}"
platform="${RELEASE_PLATFORM:-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}"
portable_name='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
if [[ ! "$version" =~ $portable_name || ! "$platform" =~ $portable_name ]]; then
    echo "release version and platform must be portable filename atoms" >&2
    exit 2
fi
out_dir="${RELEASE_OUT_DIR:-.build/release-artifacts}"
bundle_name="lattice-node-${version}-${platform}"
bundle_dir="${out_dir}/${bundle_name}"
archive="${out_dir}/${bundle_name}.tar.gz"
checksum="${archive}.sha256"
sbom="${out_dir}/${bundle_name}.spdx.json"
manifest="${out_dir}/${bundle_name}.artifacts.json"

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to generate the release SBOM" >&2
    exit 1
fi

rm -rf -- "$bundle_dir"
rm -f -- "$archive" "$checksum" "$sbom" "$manifest"
mkdir -p "$bundle_dir/bin" "$out_dir"

if [[ "${SKIP_SWIFT_BUILD:-0}" == "1" ]]; then
    RELEASE_PREBUILT_PATH="${RELEASE_PREBUILT_PATH:-$PWD/.build}" \
        RELEASE_ARTIFACT_ROOT="$PWD/.build" \
        scripts/build-release-binaries.sh
else
    RELEASE_BUILD_ROOT="$PWD/.build" \
        RELEASE_ARTIFACT_ROOT="$PWD/.build" \
        scripts/build-release-binaries.sh
fi
for product in lattice-node lattice-mining-coordinator lattice-miner; do
    cp "$PWD/.build/release-binaries/$product" "$bundle_dir/bin/$product"
done
.github/scripts/smoke-lattice-node.sh \
    "$bundle_dir/bin/lattice-node" \
    "$bundle_dir/bin/lattice-mining-coordinator" \
    "$bundle_dir/bin/lattice-miner"

cat > "$bundle_dir/README.md" <<EOF
# Lattice Node ${version} (${platform})

This archive contains the release builds for:

- lattice-node
- lattice-mining-coordinator
- lattice-miner

Linux executables statically include the Swift runtime and require the host's
glibc and SQLite runtime libraries.

Verify the archive checksum with:

\`\`\`sh
shasum -a 256 -c ${bundle_name}.tar.gz.sha256
\`\`\`

For tagged GitHub releases, also verify the signed GitHub artifact attestation:

\`\`\`sh
gh attestation verify ${bundle_name}.tar.gz --repo adalinxx/lattice-node
gh attestation verify ${bundle_name}.tar.gz --repo adalinxx/lattice-node --predicate-type https://spdx.dev/Document/v2.3
\`\`\`
EOF

tar -C "$out_dir" -czf "$archive" "$bundle_name"
archive_name="$(basename "$archive")"
checksum_name="$(basename "$checksum")"
sbom_name="$(basename "$sbom")"
manifest_name="$(basename "$manifest")"
archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$archive_sha256" "$archive_name" > "$checksum"

jq -n \
    --arg version "$version" \
    --arg platform "$platform" \
    --arg documentNamespace "https://github.com/adalinxx/lattice-node/releases/${version}/${platform}/sbom" \
    --slurpfile resolved Package.resolved '
{
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: ("lattice-node-" + $version + "-" + $platform),
  documentNamespace: $documentNamespace,
  creationInfo: {
    creators: ["Tool: lattice-node release workflow"],
    created: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  },
  packages: ([
    {
      name: "lattice-node",
      SPDXID: "SPDXRef-Package-lattice-node",
      downloadLocation: "https://github.com/adalinxx/lattice-node",
      filesAnalyzed: false,
      versionInfo: $version,
      supplier: "Person: adalinxx"
    }
  ] + ($resolved[0].pins | map({
    name: .identity,
    SPDXID: ("SPDXRef-Package-" + (.identity | gsub("[^A-Za-z0-9.-]"; "-"))),
    downloadLocation: .location,
    filesAnalyzed: false,
    versionInfo: (.state.version // .state.branch // "unversioned"),
    supplier: "NOASSERTION",
    externalRefs: [{
      referenceCategory: "PACKAGE-MANAGER",
      referenceType: "purl",
      referenceLocator: ("pkg:github/" + (.location | sub("^https://github.com/"; "") | sub("\\.git$"; "")) + "@" + .state.revision)
    }]
  }))),
  relationships: ($resolved[0].pins | map({
    spdxElementId: "SPDXRef-Package-lattice-node",
    relationshipType: "DEPENDS_ON",
    relatedSpdxElement: ("SPDXRef-Package-" + (.identity | gsub("[^A-Za-z0-9.-]"; "-")))
  }))
}
' > "$sbom"
sbom_sha256="$(shasum -a 256 "$sbom" | awk '{print $1}')"
bundle_path="$(cd "$bundle_dir" && pwd)"

jq -n \
    --arg archivePath "$archive_name" \
    --arg archiveName "$archive_name" \
    --arg archiveSHA256 "$archive_sha256" \
    --arg checksumPath "$checksum_name" \
    --arg checksumName "$checksum_name" \
    --arg sbomPath "$sbom_name" \
    --arg sbomName "$sbom_name" \
    --arg sbomSHA256 "$sbom_sha256" \
    --arg manifestPath "$manifest_name" \
    --arg manifestName "$manifest_name" '
{
  archive: {
    path: $archivePath,
    name: $archiveName,
    sha256: $archiveSHA256
  },
  checksum: {
    path: $checksumPath,
    name: $checksumName,
    subjectName: $archiveName
  },
  sbom: {
    path: $sbomPath,
    name: $sbomName,
    sha256: $sbomSHA256,
    subjectName: $archiveName
  },
  manifest: {
    path: $manifestPath,
    name: $manifestName
  }
}
' > "$manifest"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        printf 'bundle_path=%s\n' "$bundle_path"
        printf 'archive_path=%s\n' "$archive"
        printf 'checksum_path=%s\n' "$checksum"
        printf 'sbom_path=%s\n' "$sbom"
        printf 'manifest_path=%s\n' "$manifest"
        printf 'archive_sha256=%s\n' "$archive_sha256"
    } >> "$GITHUB_OUTPUT"
fi

echo "wrote release artifacts:"
printf '  %s\n' "$archive" "$checksum" "$sbom" "$manifest"
