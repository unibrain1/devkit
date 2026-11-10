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
WRITE_SCRIPTS="flow-baseline flow-claude-block flow-commit-push-pr flow-release-milestone flow-verify-ci-review"

# A write script that has a read mode can have one rule for that mode
# only. The rule ends in ":*" after the mode, so the write mode stays out.
READ_MODE_RULES=("Bash(flow-baseline --status:*)" "Bash(flow-labels --missing:*)")

# write_rules <allow-rule>...: print each rule that lets a write script run.
write_rules() {
    local rule name w r
    for rule in "$@"; do
        name="$(printf '%s' "$rule" | sed -nE 's/^Bash\((flow-[a-z-]+).*/\1/p')"
        [ -z "$name" ] && continue
        for r in "${READ_MODE_RULES[@]}"; do
            [ "$rule" = "$r" ] && continue 2
        done
        for w in $WRITE_SCRIPTS flow-labels; do
            [ "$name" = "$w" ] && echo "$rule"
        done
    done
}

missing=""
allow_rules=()
while IFS= read -r rule; do
    allow_rules+=("$rule")
    name="$(printf '%s' "$rule" | sed -nE 's/^Bash\((flow-[a-z-]+).*/\1/p')"
    [ -z "$name" ] && continue
    [ -x "$BIN/$name" ] || missing="$missing $name"
done < <(jq -r '.permissions.allow[]' "$TEMPLATE")
writes="$(write_rules "${allow_rules[@]}")"

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

# Negative control: the check must catch a write mode of a script that has
# an allowed read mode, and a write script with no mode.
for bad in "Bash(flow-baseline --apply:*)" "Bash(flow-baseline:*)" "Bash(flow-baseline --status --apply:*)" \
    "Bash(flow-labels --create:*)" "Bash(flow-labels:*)" "Bash(flow-claude-block:*)"; do
    if [ -n "$(write_rules "Bash(flow-repo:*)" "$bad")" ]; then
        pass "control: the check finds $bad"
    else
        fail "control: the check finds $bad"
    fi
done

for rule in "${READ_MODE_RULES[@]}"; do
    if jq -e --arg r "$rule" '.permissions.allow | index($r)' "$TEMPLATE" >/dev/null; then
        pass "allow has $rule"
    else
        fail "allow has $rule"
    fi
done

if jq -e '.permissions.allow as $a | $a == ($a | sort)' "$TEMPLATE" >/dev/null; then
    pass "allow list is in alphabetical order"
else
    fail "allow list is in alphabetical order"
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
