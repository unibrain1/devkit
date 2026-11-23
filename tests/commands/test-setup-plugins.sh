#!/bin/bash
#
# Tests the plugin text of /flow:setup (setup.md):
#   - Step 2 runs flow-plugins with --running.
#   - With --check, a `missing` or `stale` line marks the plugins result as
#     `failed`.
#   - Step 7 names the source of the list and the marketplace of each
#     plugin before the approval.
#   - Step 7 runs flow-plugins --status again after the approved commands,
#     and records the plugins as failed when that run exits 2.
#   - Step 7 gives the fix forms of a `stale-running` line.
#   - Step 7 replaces the update of a user-scope flow with an uninstall at
#     user scope and an install at project scope. The settings doc says so
#     too.
#   - Step 7 shows the marketplace source that the repo sets.
#   - Step 7 compares .claude/settings.json with HEAD only when HEAD has
#     the file, and runs `git checkout` only when both `jq` commands exit 0
#     and their outputs are equal.
#
# Each check also runs on a copy of setup.md without the text. That copy
# must fail, so the check can find a removed rule.
#
# Usage: bash tests/commands/test-setup-plugins.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# shellcheck disable=SC2016 # the backticks are Markdown text, not commands
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="$REAL_REPO/plugins/flow/commands/setup.md"
SETTINGS_DOC="$REAL_REPO/docs/settings-template.md"
TMPROOT="$(mktemp -d)" || exit 1

# section <file> <heading>: the text of one "## " section on one line, with
# each run of spaces made one space. Text wraps at any word, so the checks
# match words, not lines.
section() {
    awk -v h="$2" '
        /^## / { on = ($0 == h); next }
        on { printf "%s ", $0 }
    ' "$1" | tr -s ' \t' '  '
}

# The checks. Each one returns 0 when the rule is in the file.
has_running() {
    [[ "$(section "$1" '## Step 2: Read the current state')" == *'Run `flow-plugins --status --running "${CLAUDE_PLUGIN_ROOT}"`'* ]]
}
check_marks_failed() {
    [[ "$(section "$1" '## Step 2: Read the current state')" == *'has `--check`'*'A `missing` or `stale` line marks the plugins result as `failed`.'* ]]
}
names_source_before_approval() {
    [[ "$(section "$1" '## Step 7: Install or update the enabled plugins')" \
        == *'the list comes from `enabledPlugins` in this repo'"'"'s `.claude/settings.json`'*'Name the marketplace of each plugin'*'Ask for approval.'* ]]
}
reruns_status() {
    [[ "$(section "$1" '## Step 7: Install or update the enabled plugins')" \
        == *'Run each approved command.'*'Run `flow-plugins --status` again.'* ]]
}

STEP7='## Step 7: Install or update the enabled plugins'
stale_running_forms() {
    [[ "$(section "$1" "$STEP7")" == *'- `stale-running`: the fix is one of these forms: `claude plugin update <plugin> --scope <scope>` with the scope of the install, `restart the session`, or `claude plugin install <plugin> --scope project` when no install exists.'* ]]
}
user_flow_reinstall() {
    [[ "$(section "$1" "$STEP7")" \
        == *'`flow@<mkt>` with the scope `user`: do not show the update command.'*'`claude plugin uninstall flow@<mkt> --scope user` and `claude plugin install flow@<mkt> --scope project`.'*'(design section 5)'* ]]
}
shows_mkt_source() {
    [[ "$(section "$1" "$STEP7")" \
        == *'`extraKnownMarketplaces.<mkt>.source`, show its `repo` or `url` value. Tell the user that this repo sets that marketplace source.'*'Ask for approval.'* ]]
}
rerun_exit2_fails() {
    [[ "$(section "$1" "$STEP7")" \
        == *'Run `flow-plugins --status` again.'*'If this run exits 2, or with an exit code that is not 0 or 1, show its stderr. Record the plugins as failed.'* ]]
}
settings_head_guard() {
    [[ "$(section "$1" "$STEP7")" \
        == *'Then run `git cat-file -e HEAD:.claude/settings.json`. If it does not exit 0, `HEAD` has no copy of the file: do not compare, and go to item 8.'*'Then run this compare:'* ]]
}
# A process substitution hides a failed command, so the check also refuses
# the old `diff <(...)` form.
settings_checkout_guard() {
    local text
    text="$(section "$1" "$STEP7")"
    [[ "$text" != *'<('* ]] &&
        [[ "$text" == *'jq -S . "$tmp/head.raw" > "$tmp/head.json" && jq -S . .claude/settings.json > "$tmp/work.json"; then if cmp -s "$tmp/head.json" "$tmp/work.json"; then git checkout -- .claude/settings.json else'* ]] &&
        [[ "$text" == *'The `git checkout` runs only when both `jq` commands exit 0 and the two files are equal.'* ]]
}
# The doc gives the same compare as setup.md, so a person who follows the
# doc gets the same guard.
settings_doc_compare_guard() {
    local text
    text="$(tr -s ' \n' '  ' < "$1")"
    [[ "$text" == *'`git cat-file -e HEAD:.claude/settings.json`'* ]] &&
        [[ "$text" == *'jq -S . "$tmp/head.raw" > "$tmp/head.json" && jq -S . .claude/settings.json > "$tmp/work.json"; then if cmp -s "$tmp/head.json" "$tmp/work.json"; then git checkout -- .claude/settings.json else'* ]] &&
        [[ "$text" != *'diff <(git show'* ]]
}
settings_doc_user_flow() {
    [[ "$(tr -s ' \n' '  ' < "$1")" \
        == *'`claude plugin uninstall flow@devkit --scope user` and `claude plugin install flow@devkit --scope project` in its place.'* ]]
}

# run_check <label> <function> <sed-expression that removes the rule> [file]
run_check() {
    local file="${4:-$SETUP}" broken="$TMPROOT/broken.md"
    if "$2" "$file"; then
        pass "$1"
    else
        fail "$1" "$(basename "$file") does not have the text"
    fi
    sed -E "$3" "$file" > "$broken"
    if cmp -s "$file" "$broken"; then
        fail "$1 (control)" "the sed expression changed nothing"
    elif "$2" "$broken"; then
        fail "$1 (control)" "the check passes without the text"
    else
        pass "$1 (control: fails without the text)"
    fi
}

run_check "Step 2 runs flow-plugins with --running" has_running \
    's/--status --running "\$\{CLAUDE_PLUGIN_ROOT\}"/--status/'
run_check "--check: missing or stale marks plugins as failed" check_marks_failed \
    's/^or `stale` line marks the plugins result as `failed`\.$/or `stale` line is a note./'
run_check "Step 7 names the list source and the marketplace before approval" names_source_before_approval \
    's/Name the marketplace of each plugin/Name each plugin/'
run_check "Step 7 runs flow-plugins --status again after the commands" reruns_status \
    's/^6\. Run `flow-plugins --status` again\./6. Report the commands./'
run_check "Step 7 gives the fix forms of a stale-running line" stale_running_forms \
    's/^   - `stale-running`: the fix is one of these forms:$/   - `stale-running`: see the line./'
run_check "Step 7 reinstalls a user-scope flow at project scope" user_flow_reinstall \
    's/claude plugin uninstall flow@<mkt> --scope user/claude plugin update flow@<mkt> --scope user/'
run_check "Step 7 shows the marketplace source that the repo sets" shows_mkt_source \
    's/^   Tell the user that this repo sets that marketplace source\.$/   Go on./'
run_check "Step 7 records the plugins as failed when the second run exits 2" rerun_exit2_fails \
    's/If this run exits 2, or with an exit/If this run ends with an exit/'
run_check "Step 7 compares settings.json only when HEAD has the file" settings_head_guard \
    's/^   `git cat-file -e HEAD:\.claude\/settings\.json`\. If it does not exit 0,$/   `git status`. If it does not exit 0,/'
run_check "Step 7 checks out settings.json only after both jq runs and an equal compare" settings_checkout_guard \
    's/^     if cmp -s "\$tmp\/head\.json" "\$tmp\/work\.json"; then$/     if true; then/'
run_check "settings-template.md: a user-scope flow is reinstalled at project scope" settings_doc_user_flow \
    's/claude plugin uninstall flow@devkit --scope user/claude plugin update flow@devkit --scope user/' "$SETTINGS_DOC"
run_check "settings-template.md: the compare checks out only after both jq runs and an equal compare" settings_doc_compare_guard \
    's/^     if cmp -s "\$tmp\/head\.json" "\$tmp\/work\.json"; then$/     if true; then/' "$SETTINGS_DOC"

harness_report
