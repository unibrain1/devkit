#!/bin/bash
#
# Tests for templates/settings.json: the starter settings that each project
# copies one time (design section 5). The allowlist must name only flow
# scripts that exist and that change nothing, so a rename or a new write
# script cannot slip into every project.
#
# Usage: bash tests/templates/test-settings-template.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$REAL_REPO/templates/settings.json"
BIN="$REAL_REPO/plugins/flow/bin"

if jq empty "$TEMPLATE" 2>/dev/null; then
    pass "template is valid JSON"
else
    fail "template is valid JSON" "$TEMPLATE"
    harness_report
fi

# Scripts that push, merge, write files, or start workflows. A person must
# approve each run, so they never go in the starter allowlist.
WRITE_SCRIPTS="flow-claude-block flow-commit-push-pr flow-release-milestone flow-verify-ci-review"

missing=""
writes=""
while IFS= read -r rule; do
    name="$(printf '%s' "$rule" | sed -nE 's/^Bash\((flow-[a-z-]+).*/\1/p')"
    [ -z "$name" ] && continue
    [ -x "$BIN/$name" ] || missing="$missing $name"
    for w in $WRITE_SCRIPTS; do
        [ "$name" = "$w" ] && writes="$writes $name"
    done
    if [ "$name" = "flow-labels" ] && [ "$rule" != "Bash(flow-labels --missing:*)" ]; then
        writes="$writes $rule"
    fi
done < <(jq -r '.permissions.allow[]' "$TEMPLATE")

if [ -z "$missing" ]; then
    pass "each allowed flow script exists in plugins/flow/bin"
else
    fail "each allowed flow script exists" "missing:$missing"
fi

if [ -z "$writes" ]; then
    pass "no allowed flow script writes or pushes"
else
    fail "no allowed flow script writes or pushes" "found:$writes"
fi

if jq -e '.permissions.allow[] | select(test("^Bash\\(gh (api|pr (create|merge|edit|comment|close)|issue (create|edit|comment|close)|workflow run)"))' "$TEMPLATE" >/dev/null; then
    fail "no allowed gh command writes" "$(jq -r '.permissions.allow[] | select(startswith("Bash(gh"))' "$TEMPLATE")"
else
    pass "no allowed gh command writes"
fi

for rule in "Skill(commit-commands:commit-push-pr)" "Skill(commit-commands:commit-push-pr:*)"; do
    if jq -e --arg r "$rule" '.permissions.deny | index($r)' "$TEMPLATE" >/dev/null; then
        pass "deny has $rule"
    else
        fail "deny has $rule"
    fi
done

if [ "$(jq -r '.enabledPlugins["flow@devkit"]' "$TEMPLATE")" = "true" ] \
    && [ "$(jq -r '.extraKnownMarketplaces.devkit.source.repo' "$TEMPLATE")" = "unibrain1/devkit" ]; then
    pass "marketplace and flow plugin are on"
else
    fail "marketplace and flow plugin are on"
fi

harness_report
