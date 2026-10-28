#!/bin/bash
#
# Compares each upstream plugin pin in the marketplace with the upstream
# default branch HEAD. When upstream moved, it writes the new SHA into the
# marketplace file and into docs/sources.md. upstream-sync.yml then opens a
# PR, so a bad upstream change reaches no repo until a person merges it
# (design section 4, "Upstream plugins").
#
# Only pinned GitHub sources count: a "github" source, or a "url" source
# with an https://github.com/<owner>/<repo> URL, each with a "sha" key. The
# marketplace uses "url" sources, because Claude Code clones a "github"
# plugin source over SSH only. A plugin with a relative path
# (./plugins/flow) is ours and has no pin.
#
# Usage: .github/scripts/upstream-sync.sh [marketplace.json] [sources.md]
#
# Output on stdout: one line for each moved pin, tab-separated:
#   <plugin>  <owner/repo>  <old SHA>  <new SHA>
# No output means that every pin is current.
#
# Exit codes:
#   0  The check ran. The files changed only if a pin moved.
#   1  A file is missing, or gh or jq failed. No file changed.

set -euo pipefail

marketplace="${1:-.claude-plugin/marketplace.json}"
sources="${2:-docs/sources.md}"
today="${UPSTREAM_SYNC_DATE:-$(date -u +%Y-%m-%d)}"

for f in "$marketplace" "$sources"; do
    if [ ! -f "$f" ]; then
        echo "upstream-sync: file not found: $f" >&2
        exit 1
    fi
done

pins="$(jq -r '.plugins[]
    | select((.source | type) == "object" and (.source.sha // "") != "")
    | (if .source.source == "github" then .source.repo
       elif .source.source == "url" and (.source.url | test("^https://github\\.com/[^/]+/[^/]+$"))
       then (.source.url | sub("^https://github\\.com/"; "") | sub("\\.git$"; ""))
       else empty end) as $repo
    | [.name, $repo, .source.sha] | @tsv' "$marketplace")"

if [ -z "$pins" ]; then
    echo "upstream-sync: no pinned upstream plugin in $marketplace." >&2
    exit 0
fi

# Collect every result first, so that a gh failure on the second pin leaves
# both files as they were.
moved=""
while IFS=$'\t' read -r name repo old; do
    branch="$(gh api "repos/${repo}" --jq .default_branch)"
    new="$(gh api "repos/${repo}/commits/${branch}" --jq .sha)"
    if ! printf '%s' "$new" | grep -qE '^[0-9a-f]{40}$'; then
        echo "upstream-sync: ${repo}: '${new}' is not a full commit SHA." >&2
        exit 1
    fi
    if [ "$new" = "$old" ]; then
        echo "upstream-sync: ${name}: current at ${old:0:7}." >&2
        continue
    fi
    echo "upstream-sync: ${name}: ${old:0:7} -> ${new:0:7}." >&2
    moved="${moved}${name}"$'\t'"${repo}"$'\t'"${old}"$'\t'"${new}"$'\n'
done <<< "$pins"

[ -z "$moved" ] && exit 0

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

while IFS=$'\t' read -r name repo old new; do
    [ -z "$name" ] && continue
    jq --indent 2 --arg n "$name" --arg s "$new" \
        '(.plugins[] | select(.name == $n) | .source.sha) = $s' \
        "$marketplace" > "$tmp"
    cat "$tmp" > "$marketplace"

    # sources.md names the pin in full and short form, and gives the pin
    # date in the same row. Change only the rows that hold the old SHA.
    awk -v old="$old" -v new="$new" -v day="$today" '
        index($0, old) {
            gsub(old, new)
            gsub(substr(old, 1, 7), substr(new, 1, 7))
            gsub(/\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/, "(" day ")")
        }
        { print }
    ' "$sources" > "$tmp"
    cat "$tmp" > "$sources"
done <<< "$moved"

printf '%s' "$moved"
