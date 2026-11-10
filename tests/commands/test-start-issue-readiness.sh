#!/bin/bash
#
# Tests the readiness check in plugins/flow/commands/start-issue.md. The
# check runs a jq filter on the issue JSON. The test takes the filter from
# the command text and runs it on fixture issues. The check must accept an
# "Acceptance criteria" heading at level 2 or 3, and must reject all other
# text.
#
# Known limit: the filter reads lines, not Markdown. A heading inside a
# fenced code block matches too. The test records this in a case.
#
# START_ISSUE points the test at a copy of start-issue.md.
#
# Usage: bash tests/commands/test-start-issue-readiness.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
START_ISSUE="${START_ISSUE:-$REAL_REPO/plugins/flow/commands/start-issue.md}"

# The filter is the text between "--jq '" and the last "'" on the line that
# names acceptance_criteria.
FILTER="$(grep -F 'acceptance_criteria:' "$START_ISSUE" | grep -F -- "--jq '" | head -n 1 \
    | sed -e "s/^.*--jq '//" -e "s/'[^']*\$//")"

if [ -z "$FILTER" ]; then
    fail "extract the jq filter from start-issue.md" "no --jq line with acceptance_criteria found"
    harness_report
fi

# check_body <label> <expect: true|false> <body>
check_body() {
    local label="$1" expect="$2" body="$3" got
    got="$(jq -n --arg b "$body" '{milestone: {title: "v1"}, labels: [{name: "status:ready"}], body: $b}' \
        | jq -c "$FILTER" | jq -r '.acceptance_criteria')"
    if [ "$got" = "$expect" ]; then
        pass "$label"
    else
        fail "$label" "expected $expect, got $got"
    fi
}

NL=$'\n'
TAB=$'\t'
CR=$'\r'

# Match
check_body "match: ## heading"            true  "## Acceptance criteria"
check_body "match: ### heading"           true  "### Acceptance criteria"
check_body "match: upper case"            true  "## ACCEPTANCE CRITERIA"
check_body "match: mixed case"            true  "### acceptance Criteria"
check_body "match: tab after hashes"      true  "##${TAB}Acceptance criteria"
check_body "match: text after heading"    true  "## Acceptance criteria (draft)"
check_body "match: after other lines"     true  "Intro text${NL}${NL}## Summary${NL}x${NL}### Acceptance criteria${NL}- [ ] a"
check_body "match: CRLF body"             true  "Intro${CR}${NL}### Acceptance criteria${CR}${NL}- [ ] a${CR}"
check_body "match: heading in code fence (known limit)" true "${NL}\`\`\`${NL}## Acceptance criteria${NL}\`\`\`"

# No match
check_body "no match: # heading"          false "# Acceptance criteria"
check_body "no match: #### heading"       false "#### Acceptance criteria"
check_body "no match: no space"           false "##Acceptance criteria"
check_body "no match: leading space"      false " ## Acceptance criteria"
check_body "no match: empty body"         false ""
check_body "no match: Acceptance only"    false "## Acceptance"
check_body "no match: prose"              false "Write the acceptance criteria in a ## section later."

# null body
got="$(echo '{"milestone":{"title":"v1"},"labels":[{"name":"status:ready"}],"body":null}' \
    | jq -r "$FILTER | .acceptance_criteria")"
if [ "$got" = "false" ]; then pass "no match: null body"; else fail "no match: null body" "got $got"; fi

# milestone and status_ready
got="$(echo '{"milestone":null,"labels":[],"body":"## Acceptance criteria"}' | jq -c "$FILTER")"
if [ "$got" = '{"milestone":"none","status_ready":false,"acceptance_criteria":true}' ]; then
    pass "milestone none, status_ready false"
else
    fail "milestone none, status_ready false" "got $got"
fi
got="$(echo '{"milestone":{"title":"v1.2"},"labels":[{"name":"bug"},{"name":"status:ready"}],"body":"x"}' | jq -c "$FILTER")"
if [ "$got" = '{"milestone":"v1.2","status_ready":true,"acceptance_criteria":false}' ]; then
    pass "milestone title, status_ready true"
else
    fail "milestone title, status_ready true" "got $got"
fi

harness_report
