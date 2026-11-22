#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

allowlist=".github/strict-concurrency-unsafe-allowlist.txt"
if [[ ! -f "$allowlist" ]]; then
    echo "::error file=$allowlist::missing strict-concurrency unsafe allowlist"
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/KnownUnsafeConcurrencyFixture.swift"
cat > "$fixture" <<'SWIFT'
final class UnsafeCounter {
    var value = 0
}

func acceptsSendable(_ body: @escaping @Sendable () -> Void) {
    body()
}

func exerciseKnownRace() {
    let counter = UnsafeCounter()
    acceptsSendable {
        counter.value += 1
    }
}
SWIFT

fixture_log="$tmp_dir/fixture.log"
if swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -typecheck -parse-as-library "$fixture" >"$fixture_log" 2>&1; then
    cat "$fixture_log"
    echo "::error::strict concurrency accepted the known unsafe shared-mutable fixture"
    exit 1
fi
if ! grep -Eq 'non-Sendable|Sendable|concurrency-safe|data race|actor' "$fixture_log"; then
    cat "$fixture_log"
    echo "::error::known unsafe fixture failed for a non-concurrency reason"
    exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
    echo "::error::ripgrep is required for strict-concurrency unsafe-site auditing"
    exit 1
fi

occurrences="$tmp_dir/unsafe-sites.txt"
rg -n --no-heading '@unchecked Sendable|nonisolated\(unsafe\)' Sources Tools Tests > "$occurrences" || true

missing=0
while IFS=: read -r path _line source; do
    [[ -n "${path:-}" ]] || continue
    source="$(printf '%s' "$source" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    key="$path|$source|"
    if ! grep -Fq -- "$key" "$allowlist"; then
        echo "::error file=$path::unsafe concurrency escape is missing from $allowlist: $source"
        missing=1
    fi
done < "$occurrences"

stale=0
while IFS='|' read -r path source rationale; do
    [[ -n "${path:-}" ]] || continue
    [[ "$path" != \#* ]] || continue
    if [[ -z "${source:-}" || -z "${rationale:-}" ]]; then
        echo "::error file=$allowlist::allowlist entries must be path|source|rationale"
        stale=1
        continue
    fi
    if ! rg -Fq -- "$source" "$path"; then
        echo "::error file=$allowlist::stale strict-concurrency allowlist entry: $path|$source"
        stale=1
    fi
done < "$allowlist"

if [[ "$missing" -ne 0 || "$stale" -ne 0 ]]; then
    exit 1
fi

swift build -Xswiftc -strict-concurrency=complete
