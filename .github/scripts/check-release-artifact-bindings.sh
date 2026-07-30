#!/usr/bin/env bash
set -euo pipefail

die() {
    echo "release artifact binding check failed: $*" >&2
    exit 1
}

json_string() {
    local file="$1"
    local query="$2"
    jq -er "$query" "$file"
}

artifact_path() {
    local manifest="$1"
    local reference="$2"

    [[ -n "$reference" && "$reference" != */* ]] \
        || die "$manifest contains a non-portable artifact path: $reference"
    printf '%s/%s\n' "$(dirname "$manifest")" "$reference"
}

write_manifest() {
    local manifest="$1"
    local archive="$2"
    local checksum="$3"
    local sbom="$4"
    local digest="$5"
    local subject="$6"

    jq -n \
        --arg archivePath "$(basename "$archive")" \
        --arg archiveName "$(basename "$archive")" \
        --arg archiveSHA256 "$digest" \
        --arg checksumPath "$(basename "$checksum")" \
        --arg checksumName "$(basename "$checksum")" \
        --arg checksumSubject "$subject" \
        --arg sbomPath "$(basename "$sbom")" \
        --arg sbomName "$(basename "$sbom")" \
        --arg sbomSHA256 "$(shasum -a 256 "$sbom" | awk '{print $1}')" \
        --arg manifestPath "$(basename "$manifest")" \
        --arg manifestName "$(basename "$manifest")" '
{
  archive: {path: $archivePath, name: $archiveName, sha256: $archiveSHA256},
  checksum: {path: $checksumPath, name: $checksumName, subjectName: $checksumSubject},
  sbom: {path: $sbomPath, name: $sbomName, sha256: $sbomSHA256, subjectName: $archiveName},
  manifest: {path: $manifestPath, name: $manifestName}
}
' > "$manifest"
}

run_self_test() {
    local tmp archive_a archive_b checksum_a checksum_b sbom_a sbom_b manifest_a manifest_b digest_a digest_b
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    archive_a="${tmp}/alpha.tar.gz"
    archive_b="${tmp}/beta.tar.gz"
    checksum_a="${archive_a}.sha256"
    checksum_b="${archive_b}.sha256"
    sbom_a="${tmp}/alpha.spdx.json"
    sbom_b="${tmp}/beta.spdx.json"
    manifest_a="${tmp}/alpha.artifacts.json"
    manifest_b="${tmp}/beta.artifacts.json"

    printf 'alpha\n' > "$archive_a"
    printf 'beta\n' > "$archive_b"
    digest_a="$(shasum -a 256 "$archive_a" | awk '{print $1}')"
    digest_b="$(shasum -a 256 "$archive_b" | awk '{print $1}')"
    printf '%s  %s\n' "$digest_a" "$(basename "$archive_a")" > "$checksum_a"
    printf '%s  %s\n' "$digest_b" "$(basename "$archive_b")" > "$checksum_b"
    printf '{}\n' > "$sbom_a"
    printf '{}\n' > "$sbom_b"

    write_manifest "$manifest_a" "$archive_a" "$checksum_a" "$sbom_a" "$digest_a" "$(basename "$archive_a")"
    write_manifest "$manifest_b" "$archive_b" "$checksum_b" "$sbom_b" "$digest_b" "$(basename "$archive_b")"
    check_manifests "$manifest_a" "$manifest_b"
    if ( check_manifests "$manifest_a" "$manifest_a" ) >/dev/null 2>&1; then
        die "self-test accepted duplicate artifact subjects"
    fi

    printf '{"changed":true}\n' > "$sbom_a"
    if ( check_manifests "$manifest_a" ) >/dev/null 2>&1; then
        die "self-test accepted a changed SBOM"
    fi
    printf '{}\n' > "$sbom_a"

    printf '%s  %s\n' "$digest_a" "$(basename "$archive_b")" > "$checksum_a"
    if ( check_manifests "$manifest_a" ) >/dev/null 2>&1; then
        die "self-test accepted checksum bound to the wrong artifact name"
    fi
}

check_manifests() {
    local seen_subjects=$'\n'
    local manifest
    for manifest in "$@"; do
        local archive_reference archive_path archive_name archive_sha256
        local checksum_reference checksum_path checksum_name checksum_subject
        local sbom_reference sbom_path sbom_name sbom_sha256 sbom_subject
        local manifest_reference manifest_name
        archive_reference="$(json_string "$manifest" '.archive.path')"
        archive_path="$(artifact_path "$manifest" "$archive_reference")"
        archive_name="$(json_string "$manifest" '.archive.name')"
        archive_sha256="$(json_string "$manifest" '.archive.sha256')"
        checksum_reference="$(json_string "$manifest" '.checksum.path')"
        checksum_path="$(artifact_path "$manifest" "$checksum_reference")"
        checksum_name="$(json_string "$manifest" '.checksum.name')"
        checksum_subject="$(json_string "$manifest" '.checksum.subjectName')"
        sbom_reference="$(json_string "$manifest" '.sbom.path')"
        sbom_path="$(artifact_path "$manifest" "$sbom_reference")"
        sbom_name="$(json_string "$manifest" '.sbom.name')"
        sbom_sha256="$(json_string "$manifest" '.sbom.sha256')"
        sbom_subject="$(json_string "$manifest" '.sbom.subjectName')"
        manifest_reference="$(json_string "$manifest" '.manifest.path')"
        manifest_name="$(json_string "$manifest" '.manifest.name')"

        [[ -f "$archive_path" ]] || die "$manifest references missing archive: $archive_path"
        [[ -f "$checksum_path" ]] || die "$manifest references missing checksum: $checksum_path"
        [[ -f "$sbom_path" ]] || die "$manifest references missing SBOM: $sbom_path"
        [[ "$archive_reference" == "$archive_name" ]] || die "$manifest archive name does not match archive path"
        [[ "$checksum_reference" == "$checksum_name" ]] || die "$manifest checksum name does not match checksum path"
        [[ "$sbom_reference" == "$sbom_name" ]] || die "$manifest SBOM name does not match SBOM path"
        [[ "$manifest_reference" == "$manifest_name" ]] || die "$manifest name does not match manifest path"
        [[ "$(basename "$manifest")" == "$manifest_name" ]] || die "$manifest does not match its manifest name"
        [[ "$checksum_name" == "${archive_name}.sha256" ]] || die "$manifest checksum file is not named after its archive"
        [[ "$checksum_subject" == "$archive_name" ]] || die "$manifest checksum subject is not the archive name"
        [[ "$sbom_subject" == "$archive_name" ]] || die "$manifest SBOM subject is not the archive name"

        local digest subject extra computed
        read -r digest subject extra < "$checksum_path"
        [[ -z "${extra:-}" ]] || die "$checksum_path contains extra checksum fields"
        [[ "$subject" == "$archive_name" ]] || die "$checksum_path is bound to $subject, expected $archive_name"
        [[ "$digest" == "$archive_sha256" ]] || die "$checksum_path digest does not match manifest digest"
        computed="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
        [[ "$computed" == "$archive_sha256" ]] || die "$archive_path digest does not match manifest"
        computed="$(shasum -a 256 "$sbom_path" | awk '{print $1}')"
        [[ "$computed" == "$sbom_sha256" ]] || die "$sbom_path digest does not match manifest"

        case "${seen_subjects}" in
            *"
${checksum_subject}
"*) die "duplicate checksum subject: $checksum_subject" ;;
        esac
        seen_subjects="${seen_subjects}${checksum_subject}
"
    done
}

ran_self_test=0
if [[ "${1:-}" == "--self-test" ]]; then
    run_self_test
    ran_self_test=1
    shift
fi

if [[ $# -eq 0 && "$ran_self_test" == "1" ]]; then
    exit 0
fi

if [[ $# -eq 0 ]]; then
    shopt -s nullglob
    set -- .build/release-artifacts/*.artifacts.json
    shopt -u nullglob
fi

[[ $# -gt 0 ]] || die "no release artifact manifests provided"
check_manifests "$@"
