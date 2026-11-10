#!/bin/bash
#
# Fails when a workflow uses an action that is not pinned to a full commit
# SHA. A tag can move, so a SHA is the only pin that cannot change under us
# (design section 6). Local actions (./...) and docker:// images are exempt.
#
# A devkit reusable workflow, unibrain1/devkit/.github/workflows/<name>.yml
# (or .yaml), can also use @main or a full @vX.Y.Z tag. The devkit pin rule
# in docs/ci-workflows.md lets a repo with no outside contributors use
# @main, and a repo with outside contributors a release tag. A SHA also
# passes. Other devkit paths, look-alike owners or repos, other branches,
# and short tags such as @v1 or @v1.4 still fail.
#
# Known limit: the script reads only block style. It does not see a "uses:"
# key in a flow mapping, for example "- {uses: actions/checkout@v4}".
#
# Usage: .github/scripts/check-action-pins.sh [workflow-dir]
#   workflow-dir defaults to .github/workflows in the current folder.
#
# Exit codes:
#   0  Every action is pinned. A folder with no workflow files also exits 0.
#   1  One or more actions are not pinned. Each is printed on stderr.
#   2  The workflow folder does not exist, or a file in it cannot be read.

set -euo pipefail

dir="${1:-.github/workflows}"
bad=0

if [ ! -d "$dir" ]; then
    echo "check-action-pins: '${dir}' is not a folder." >&2
    exit 2
fi

# grep exits 1 when no line matches. That is a pass. It exits 2 when it
# cannot read a file, and a file that the script cannot read is not clean.
grep_rc=0
matches="$(grep -rnE '^[[:space:]-]*uses:' "$dir" --include='*.yml' --include='*.yaml')" || grep_rc=$?
if [ "$grep_rc" -gt 1 ]; then
    echo "check-action-pins: cannot read '${dir}'." >&2
    exit 2
fi

devkit_ref='^unibrain1/devkit/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@(main|v[0-9]+\.[0-9]+\.[0-9]+)$'

while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"
    rest="${line#*:}"
    lineno="${rest%%:*}"
    ref="$(printf '%s' "$rest" | sed -nE 's/^[0-9]+:[[:space:]-]*uses:[[:space:]]*["'\'']?([^"'\''[:space:]#]+).*/\1/p')"
    # An empty ref is a value that the sed cannot read, for example a
    # value on the next line. The script cannot check it, so it fails.
    if [ -z "$ref" ]; then
        echo "${file}:${lineno}: cannot read the uses value." >&2
        bad=$((bad + 1))
        continue
    fi
    case "$ref" in
        ./*|docker://*) continue ;;
    esac
    if printf '%s' "$ref" | grep -qE '@[0-9a-f]{40}$'; then
        continue
    fi
    if printf '%s' "$ref" | grep -qE "$devkit_ref"; then
        continue
    fi
    echo "${file}:${lineno}: '${ref}' is not pinned to a full commit SHA." >&2
    bad=$((bad + 1))
done <<EOF
$matches
EOF

if [ "$bad" -gt 0 ]; then
    exit 1
fi
