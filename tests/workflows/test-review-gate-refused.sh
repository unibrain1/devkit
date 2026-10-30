#!/bin/bash
#
# Tests the "Refused:" jq filter in each Gate step of claude-review.yml.
# A sandbox run of a review-workflow change passes only when the Gate shows
# no "Refused:" warning (docs/ci-workflows.md). If the filter breaks, the
# Gate prints nothing, and each run looks clean. So the test runs each
# filter on a fake execution file. The repo can be public, so the filter
# must print only the tool name and the first 3 words of a command.
#
# WORKFLOW_DIR points the test at a copy of .github/workflows.
#
# Usage: bash tests/workflows/test-review-gate-refused.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW_DIR="${WORKFLOW_DIR:-$REAL_REPO/.github/workflows}"
REVIEW="$WORKFLOW_DIR/claude-review.yml"

TMPROOT="$(mktemp -d)"

# The program starts at "jq -r '" and ends at the line that ends "' \".
# The step is a YAML literal block, so the text is the program as the
# runner sees it, with its indent.
# extract <n>: writes the program of the n-th filter to stdout.
extract() {
    awk -v want="$1" '
        /jq -r .\.\[\] \| select\(\.type == "result"\)/ { n++; on = (n == want) }
        on {
            line = $0
            sub(/^ *jq -r '\''/, "", line)
            done = sub(/'\'' \\$/, "", line)
            print line
            if (done) on = 0
        }
    ' "$REVIEW"
}

count="$(grep -c 'jq -r .\.\[\] | select(\.type == "result")' "$REVIEW" 2>/dev/null)"
label="claude-review.yml has 3 Refused filters"
if [ "${count:-0}" = 3 ]; then
    pass "$label"
else
    fail "$label" "found ${count:-0}"
fi

# One result has a Bash denial with leading space and more than 3 words, a
# Bash denial with a line break inside its first 3 words, and a Read denial
# with no command. A non-result entry and a result with no denials must
# print nothing.
cat > "$TMPROOT/exec.json" <<'EOF'
[
  {"type": "system", "permission_denials": [{"tool_name": "Ignored"}]},
  {"type": "result", "permission_denials": [
    {"tool_name": "Bash", "tool_input": {"command": "  cd /tmp && gh pr diff 5 | head"}},
    {"tool_name": "Bash", "tool_input": {"command": "cat\nsecret token here"}},
    {"tool_name": "Read", "tool_input": {"file_path": "/etc/hosts"}}
  ]},
  {"type": "result"}
]
EOF
expected="::warning::Refused: Bash cd /tmp &&
::warning::Refused: Bash cat
::warning::Refused: Read "

i=1
while [ "$i" -le "${count:-0}" ]; do
    label="filter $i prints each refused call with at most 3 words of line 1"
    extract "$i" > "$TMPROOT/prog-$i.jq"
    if ! out="$(jq -r -f "$TMPROOT/prog-$i.jq" "$TMPROOT/exec.json" 2>&1)"; then
        fail "$label" "jq failed: $out"
    elif [ "$out" = "$expected" ]; then
        pass "$label"
    else
        details=()
        while IFS= read -r p; do details+=("got: $p"); done <<< "$out"
        fail "$label" "${details[@]}"
    fi
    i=$((i + 1))
done

label="the filter prints nothing when no call was refused"
echo '[{"type": "result", "permission_denials": []}]' > "$TMPROOT/clean.json"
if [ "${count:-0}" -ge 1 ] && out="$(jq -r -f "$TMPROOT/prog-1.jq" "$TMPROOT/clean.json" 2>&1)" \
    && [ -z "$out" ]; then
    pass "$label"
else
    fail "$label" "got: ${out:-no filter}"
fi

harness_report
