#!/bin/bash
#
# Fails when a workflow uses an action that is not pinned to a full commit
# SHA. A tag can move, so a SHA is the only pin that cannot change under us
# (design section 6). Local actions (./...) and docker:// images are exempt.
#
# Usage: .github/scripts/check-action-pins.sh [workflow-dir]
#
# Exit codes:
#   0  Every action is pinned to a 40-character SHA.
#   1  One or more actions are not pinned. Each is printed on stderr.

set -euo pipefail

dir="${1:-.github/workflows}"
bad=0

while IFS= read -r line; do
    file="${line%%:*}"
    rest="${line#*:}"
    lineno="${rest%%:*}"
    ref="$(printf '%s' "$rest" | sed -nE 's/^[0-9]+:[[:space:]-]*uses:[[:space:]]*["'\'']?([^"'\''[:space:]#]+).*/\1/p')"
    case "$ref" in
        ""|./*|docker://*) continue ;;
    esac
    if ! printf '%s' "$ref" | grep -qE '@[0-9a-f]{40}$'; then
        echo "${file}:${lineno}: '${ref}' is not pinned to a full commit SHA." >&2
        bad=$((bad + 1))
    fi
done < <(grep -rnE '^[[:space:]-]*uses:' "$dir" --include='*.yml' --include='*.yaml' || true)

if [ "$bad" -gt 0 ]; then
    exit 1
fi
