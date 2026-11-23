#!/bin/bash
#
# Tests for plugins/flow/bin/flow-plugins: the check that the plugins a repo
# enables are installed at the version the marketplace expects.
#
# HERMETIC: CLAUDE_CONFIG_DIR and HOME point into $TMPROOT, so the real
# ~/.claude never changes a result. The marketplace is a local git repo.
# No case uses the network.
#
# Usage: bash tests/bin/test-flow-plugins.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The jq filters use jq variables such as $p, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-plugins"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(cd -P "$(mktemp -d)" && pwd)" || exit 1
export HOME="$TMPROOT/home"
export CLAUDE_CONFIG_DIR="$TMPROOT/cfg"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/plugins"
PLUGINS="$CLAUDE_CONFIG_DIR/plugins"

ASD_SHA="9c351694439e0123456789abcdef0123456789ab"
ASD12="9c351694439e"
OLD12="aaaaaaaaaaaa"

gitc() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# make_mkt <dir>: a marketplace checkout with flow (relative source),
# asd-ste100 (sha source), and other (github source, no version).
make_mkt() {
    mkdir -p "$1/.claude-plugin"
    jq -n --arg sha "$ASD_SHA" '{name: "devkit", plugins: [
        {name: "flow", source: "./plugins/flow"},
        {name: "asd-ste100", source: {source: "url", url: "https://example.invalid/x.git", sha: $sha}},
        {name: "other", source: {source: "github", repo: "x/y"}}]}' \
        > "$1/.claude-plugin/marketplace.json"
    git init -q "$1" >/dev/null 2>&1
    gitc -C "$1" add -A >/dev/null
    gitc -C "$1" commit -q -m one >/dev/null
}

# write_known <mkt-name> <install-location>
write_known() {
    jq -n --arg m "$1" --arg l "$2" \
        '{($m): {source: {source: "github", repo: "unibrain1/devkit", ref: "main"}, installLocation: $l, autoUpdate: true}}' \
        > "$PLUGINS/known_marketplaces.json"
}

# entry <scope> <project-path or ""> <version>: one install record.
entry() {
    jq -n --arg s "$1" --arg p "$2" --arg v "$3" \
        '{scope: $s, installPath: ("/cache/x/" + $v), version: $v, installedAt: "t", lastUpdated: "t", gitCommitSha: ($v + "0000000000000000000000000000")}
         | if $s == "user" then del(.projectPath) else . + {projectPath: $p} end'
}

# write_installed <key> <entry-json> [<key> <entry-json>]...: entries for the
# same key go into one array, in the given order.
write_installed() {
    local doc='{"version": 2, "plugins": {}}'
    while [ "$#" -ge 2 ]; do
        doc="$(printf '%s' "$doc" | jq --arg k "$1" --argjson e "$2" '.plugins[$k] += [$e]')"
        shift 2
    done
    printf '%s\n' "$doc" > "$PLUGINS/installed_plugins.json"
}

# write_settings <repo> <key>...: enable each key.
write_settings() {
    local repo="$1" doc='{"enabledPlugins": {}}'
    shift
    mkdir -p "$repo/.claude"
    for k in "$@"; do
        doc="$(printf '%s' "$doc" | jq --arg k "$k" '.enabledPlugins[$k] = true')"
    done
    printf '%s\n' "$doc" > "$repo/.claude/settings.json"
}

ALL_RCS=""
# run <args...>: sets OUT, ERR, RC in the current folder.
run() {
    OUT="$("$SCRIPT" "$@" 2>"$TMPROOT/stderr")"
    RC=$?
    ERR="$(cat "$TMPROOT/stderr")"
    ALL_RCS="$ALL_RCS $RC"
}

# expect <label> <want-rc> <want-stdout>
expect() {
    if [ "$RC" -eq "$2" ] && [ "$OUT" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "exit: $RC (want $2)" "stdout: [$OUT]" "want:   [$3]" "stderr: [$ERR]"
    fi
}

MKT="$TMPROOT/marketplace"
make_mkt "$MKT"
write_known devkit "$MKT"
HEAD12="$(git -C "$MKT" rev-parse HEAD | cut -c1-12)"

REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1
write_settings "$REPO" flow@devkit asd-ste100@devkit

FIX_UPD_FLOW="fix: claude plugin update flow@devkit --scope project"

# A1: both plugins current.
write_installed flow@devkit "$(entry project "$REPO" "$HEAD12")" \
    asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
run --status
expect "A1 all current -> ok lines, exit 0" 0 "ok flow@devkit ${HEAD12}
ok asd-ste100@devkit ${ASD12}"

# A2: a plugin with the value false is not checked.
mkdir -p .claude
printf '{"enabledPlugins": {"flow@devkit": false}}\n' > .claude/settings.json
run --status
expect "A2 none enabled -> silent, exit 0" 0 ""
write_settings "$REPO" flow@devkit asd-ste100@devkit

# A3: no install for flow.
write_installed asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
run --status
expect "A3 missing -> exact fix line, exit 1" 1 "missing flow@devkit  fix: claude plugin install flow@devkit --scope project
ok asd-ste100@devkit ${ASD12}"

# A4 and A9: a second marketplace commit makes the install stale. The
# expected version of a relative source is the marketplace HEAD.
write_installed flow@devkit "$(entry project "$REPO" "$HEAD12")" \
    asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
printf 'x\n' > "$MKT/new-file"
gitc -C "$MKT" add -A >/dev/null
gitc -C "$MKT" commit -q -m two >/dev/null
NEW12="$(git -C "$MKT" rev-parse HEAD | cut -c1-12)"
run --status
expect "A4 stale -> exact fix line, exit 1" 1 "stale flow@devkit ${HEAD12} ${NEW12}  ${FIX_UPD_FLOW}
ok asd-ste100@devkit ${ASD12}"
if [ "$NEW12" != "$HEAD12" ] && [[ "$OUT" == *" ${NEW12} "* ]]; then
    pass "A9 relative source expects the marketplace HEAD"
else
    fail "A9 relative source expects the marketplace HEAD" "stdout: [$OUT]" "head: $NEW12"
fi
HEAD12="$NEW12"

# A5: a user-scope install counts.
write_installed flow@devkit "$(entry user "" "$HEAD12")" \
    asd-ste100@devkit "$(entry user "" "$ASD12")"
run --status
expect "A5 user scope counts as installed" 0 "ok flow@devkit ${HEAD12}
ok asd-ste100@devkit ${ASD12}"

# A6: a project install for another repo does not count.
write_installed flow@devkit "$(entry project "$TMPROOT/other-repo" "$HEAD12")" \
    asd-ste100@devkit "$(entry local "$TMPROOT/other-repo" "$ASD12")"
run --status
expect "A6 other projectPath -> missing" 1 "missing flow@devkit  fix: claude plugin install flow@devkit --scope project
missing asd-ste100@devkit  fix: claude plugin install asd-ste100@devkit --scope project"

# A7: with two records, the one for this repo wins, in each order. A user
# record does not win over a project record for this repo.
mkdir -p "$TMPROOT/other-repo"
write_installed flow@devkit "$(entry project "$TMPROOT/other-repo" "$OLD12")" \
    flow@devkit "$(entry local "$REPO" "$HEAD12")" \
    asd-ste100@devkit "$(entry user "" "$OLD12")" \
    asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
run --status
expect "A7 two records pick this repo" 0 "ok flow@devkit ${HEAD12}
ok asd-ste100@devkit ${ASD12}"
write_installed flow@devkit "$(entry project "$REPO" "$OLD12")" \
    flow@devkit "$(entry project "$TMPROOT/other-repo" "$HEAD12")"
write_settings "$REPO" flow@devkit
run --status
expect "A7 two records, this repo stale -> stale" 1 "stale flow@devkit ${OLD12} ${HEAD12}  ${FIX_UPD_FLOW}"

# A8: a sha source compares with the sha.
write_settings "$REPO" asd-ste100@devkit
write_installed asd-ste100@devkit "$(entry project "$REPO" "$OLD12")"
run --status
expect "A8 sha source, other version -> stale" 1 \
    "stale asd-ste100@devkit ${OLD12} ${ASD12}  fix: claude plugin update asd-ste100@devkit --scope project"

# A8b: an upstream plugin can set a semver version. Then only gitCommitSha
# shows that the install is the expected sha.
printf '%s\n' "{\"version\": 2, \"plugins\": {\"asd-ste100@devkit\": [{\"scope\": \"project\", \"projectPath\": \"$REPO\", \"version\": \"1.0.0\", \"gitCommitSha\": \"$ASD_SHA\"}]}}" \
    > "$PLUGINS/installed_plugins.json"
run --status
expect "A8b sha source, semver version, gitCommitSha is the sha -> ok" 0 \
    "ok asd-ste100@devkit ${ASD12}"

# B1: a user record has no projectPath. The empty field must not move the
# version and the sha. The version is not the sha.
write_settings "$REPO" flow@devkit
printf '%s\n' '{"version": 2, "plugins": {"flow@devkit": [{"scope": "user", "version": "1.2.0", "gitCommitSha": "aaaaaaaaaaaa0000"}]}}' \
    > "$PLUGINS/installed_plugins.json"
run --status
expect "B1 user record, version is not the sha -> installed 1.2.0" 1 \
    "stale flow@devkit 1.2.0 ${HEAD12}  fix: claude plugin update flow@devkit --scope user"

# B2: the fix command keeps the scope of the install.
write_installed flow@devkit "$(entry user "" "$OLD12")"
run --status
expect "B2 stale user install -> --scope user" 1 \
    "stale flow@devkit ${OLD12} ${HEAD12}  fix: claude plugin update flow@devkit --scope user"
write_installed flow@devkit "$(entry local "$REPO" "$OLD12")"
run --status
expect "B2 stale local install -> --scope local" 1 \
    "stale flow@devkit ${OLD12} ${HEAD12}  fix: claude plugin update flow@devkit --scope local"
write_installed flow@devkit "$(entry project "$REPO" "$OLD12")"
run --status
expect "B2 stale project install -> --scope project" 1 \
    "stale flow@devkit ${OLD12} ${HEAD12}  ${FIX_UPD_FLOW}"

# C1: a marketplace ref in this repo. The same ref as the checkout compares
# as usual. Another ref gives unknown, because the checkout does not show
# the version that this repo expects.
set_ref() {
    jq --arg r "$1" '.extraKnownMarketplaces.devkit = {source: {source: "github", repo: "unibrain1/devkit", ref: $r}}' \
        "$REPO/.claude/settings.json" > "$TMPROOT/s.json" && mv "$TMPROOT/s.json" "$REPO/.claude/settings.json"
}
set_ref main
run --status
expect "C1 repo ref = checkout ref -> normal compare" 1 \
    "stale flow@devkit ${OLD12} ${HEAD12}  ${FIX_UPD_FLOW}"
set_ref v1.0.0
run --status
expect "C1 repo ref != checkout ref -> unknown, exit 0" 0 "unknown flow@devkit"
if [[ "$ERR" == *"pins marketplace ref v1.0.0"* ]] && [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = 1 ]; then
    pass "C1 ref mismatch -> one stderr line with the reason"
else
    fail "C1 ref mismatch -> one stderr line with the reason" "stderr: [$ERR]"
fi
run --status --running "$TMPROOT/cache/devkit/flow/${OLD12}"
expect "C1 ref mismatch -> no stale-running line" 0 "unknown flow@devkit"
write_settings "$REPO" flow@devkit

# C2: the checkout of a relative source has a .git that git cannot read.
# The expected version is not known, so the script stops with exit 2. A
# checkout with no .git (a download) gives unknown.
mv "$MKT/.git" "$TMPROOT/mkt-git"
run --status
expect "C2 marketplace with no .git -> unknown, exit 0" 0 "unknown flow@devkit"
printf 'gitdir: %s\n' "$TMPROOT/no-such-dir" > "$MKT/.git"
run --status
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [[ "$ERR" == *"cannot read the git commit"* ]]; then
    pass "C2 marketplace .git that git cannot read -> exit 2"
else
    fail "C2 marketplace .git that git cannot read -> exit 2" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
fi
rm -f "$MKT/.git"
mv "$TMPROOT/mkt-git" "$MKT/.git"

# C3: a key that fails the name check is skipped. stderr names it with
# unsafe characters changed. stdout never shows it.
write_installed flow@devkit "$(entry project "$REPO" "$HEAD12")"
jq -n '{enabledPlugins: {"-x@devkit": true, "a@b@c": true, "bad\nkey@devkit": true, "x;rm@devkit": true, "flow@devkit": true}}' \
    > "$REPO/.claude/settings.json"
run --status
expect "C3 bad keys -> skipped, good key checked" 0 "ok flow@devkit ${HEAD12}"
if [ "$(printf '%s\n' "$ERR" | grep -c 'skipped the enabledPlugins key')" = 4 ] \
    && [[ "$ERR" == *"key -x@devkit:"* ]] && [[ "$ERR" == *"key bad?key@devkit:"* ]] \
    && [[ "$ERR" == *"key x?rm@devkit:"* ]] && [[ "$ERR" != *";"* ]]; then
    pass "C3 one stderr line for each skipped key, unsafe characters changed"
else
    fail "C3 one stderr line for each skipped key, unsafe characters changed" "stderr: [$ERR]"
fi
write_settings "$REPO" flow@devkit

# A10: a source with no version is unknown, not a failure.
write_settings "$REPO" other@devkit
write_installed other@devkit "$(entry project "$REPO" "$OLD12")"
run --status
expect "A10 unknown source -> unknown, exit 0" 0 "unknown other@devkit"
if [ -z "$ERR" ]; then
    pass "A10 control: a listed plugin with no version gives no stderr reason"
else
    fail "A10 control: a listed plugin with no version gives no stderr reason" "stderr: [$ERR]"
fi
# A plugin that the marketplace.json does not list: unknown, with a reason.
write_settings "$REPO" ghost@devkit
write_installed ghost@devkit "$(entry project "$REPO" "$OLD12")"
run --status
expect "A10 plugin not in marketplace.json -> unknown, exit 0" 0 "unknown ghost@devkit"
if [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = "1" ] && [[ "$ERR" == *"ghost@devkit: the marketplace.json of devkit does not list ghost."* ]]; then
    pass "A10 plugin not in marketplace.json -> one stderr reason line"
else
    fail "A10 plugin not in marketplace.json -> one stderr reason line" "stderr: [$ERR]"
fi
write_settings "$REPO" other@nomarket
write_installed other@nomarket "$(entry project "$REPO" "$OLD12")"
run --status
expect "A10 unknown marketplace -> unknown, exit 0" 0 "unknown other@nomarket"

# A11: no installed_plugins.json.
write_settings "$REPO" flow@devkit asd-ste100@devkit
rm -f "$PLUGINS/installed_plugins.json"
run --status
expect "A11 no installed_plugins.json -> missing, exit 1" 1 "missing flow@devkit  fix: claude plugin install flow@devkit --scope project
missing asd-ste100@devkit  fix: claude plugin install asd-ste100@devkit --scope project"

# A12: a JSON file that does not parse.
write_installed flow@devkit "$(entry project "$REPO" "$HEAD12")" \
    asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
for f in "$REPO/.claude/settings.json" "$PLUGINS/installed_plugins.json" \
    "$PLUGINS/known_marketplaces.json" "$MKT/.claude-plugin/marketplace.json"; do
    cp "$f" "$TMPROOT/saved.json"
    printf '{ not json' > "$f"
    run --status
    if [ "$RC" -eq 2 ] && [[ "$ERR" == *"cannot read or parse"* ]]; then
        pass "A12 bad JSON in $(basename "$f") -> exit 2"
    else
        fail "A12 bad JSON in $(basename "$f") -> exit 2" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
    cp "$TMPROOT/saved.json" "$f"
done

# A12: a JSON file that jq cannot read.
if [ "$(id -u)" -eq 0 ]; then
    pass "A12 unreadable marketplace.json: skipped as root"
else
    chmod 000 "$MKT/.claude-plugin/marketplace.json"
    run --status
    chmod 644 "$MKT/.claude-plugin/marketplace.json"
    if [ "$RC" -eq 2 ] && [[ "$ERR" == *"cannot read or parse"* ]]; then
        pass "A12 unreadable marketplace.json -> exit 2, cannot read or parse"
    else
        fail "A12 unreadable marketplace.json -> exit 2, cannot read or parse" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
fi

# A13: no settings.json.
mv "$REPO/.claude/settings.json" "$TMPROOT/settings.saved"
run --status
expect "A13 no settings.json -> silent, exit 0" 0 ""
mv "$TMPROOT/settings.saved" "$REPO/.claude/settings.json"

# A14: no jq on PATH.
NOJQ="$TMPROOT/nojq-bin"
mkdir -p "$NOJQ"
for t in git basename dirname cut tr cat; do
    ln -s "$(command -v "$t")" "$NOJQ/$t"
done
OUT="$(PATH="$NOJQ" /bin/bash "$SCRIPT" --status 2>"$TMPROOT/stderr")"
RC=$?
ERR="$(cat "$TMPROOT/stderr")"
ALL_RCS="$ALL_RCS $RC"
if [ "$RC" -eq 2 ] && [[ "$ERR" == *"jq is not installed"* ]]; then
    pass "A14 no jq -> exit 2"
else
    fail "A14 no jq -> exit 2" "exit: $RC" "stderr: [$ERR]"
fi

# A15: usage errors.
for args in "" "--apply" "--status extra" "--status --running" "--running x" "--status --other x"; do
    # shellcheck disable=SC2086 # split the argument list on purpose
    run $args
    if [ "$RC" -eq 2 ] && [[ "$ERR" == *"Usage:"* ]]; then
        pass "A15 usage error [${args}] -> exit 2"
    else
        fail "A15 usage error [${args}] -> exit 2" "exit: $RC" "stderr: [$ERR]"
    fi
done
run --status --running ""
if [ "$RC" -eq 2 ]; then pass "A15 empty --running value -> exit 2"; else fail "A15 empty --running value -> exit 2" "exit: $RC"; fi

# A16-A19: the running plugin.
OK_LINES="ok flow@devkit ${HEAD12}
ok asd-ste100@devkit ${ASD12}"
run --status --running "$TMPROOT/cache/devkit/flow/${OLD12}"
expect "A16 --running stale, install current -> restart fix, exit 1" 1 "${OK_LINES}
stale-running flow@devkit ${OLD12} ${HEAD12}  fix: restart the session"
write_installed flow@devkit "$(entry user "" "$OLD12")" \
    asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
run --status --running "$TMPROOT/cache/devkit/flow/${OLD12}"
expect "A16 --running stale, user install stale -> update --scope user" 1 \
    "stale flow@devkit ${OLD12} ${HEAD12}  fix: claude plugin update flow@devkit --scope user
ok asd-ste100@devkit ${ASD12}
stale-running flow@devkit ${OLD12} ${HEAD12}  fix: claude plugin update flow@devkit --scope user"
write_installed flow@devkit "$(entry project "$REPO" "$HEAD12")" \
    asd-ste100@devkit "$(entry project "$REPO" "$ASD12")"
run --status --running "$TMPROOT/cache/devkit/flow/${HEAD12}"
expect "A17 --running current -> no line" 0 "$OK_LINES"
run --status --running "$REAL_REPO/plugins/flow"
expect "A18 --running non-hex (--plugin-dir) -> skipped" 0 "$OK_LINES"
run --status --running "$TMPROOT/cache/nomarket/flow/${OLD12}"
expect "A19 --running unknown marketplace -> skipped" 0 "$OK_LINES"

# A20: a repo path with spaces, recorded through a symbolic link.
SPACED="$TMPROOT/my repo"
git init -q "$SPACED" >/dev/null 2>&1
ln -s "$SPACED" "$TMPROOT/link to repo"
write_settings "$SPACED" flow@devkit
write_installed flow@devkit "$(entry project "$TMPROOT/link to repo" "$HEAD12")"
cd "$SPACED" || exit 1
run --status
expect "A20 path with spaces, linked projectPath -> ok" 0 "ok flow@devkit ${HEAD12}"

# A22: run from a subfolder.
mkdir -p "$SPACED/sub/dir"
cd "$SPACED/sub/dir" || exit 1
run --status
expect "A22 run from a subfolder -> ok" 0 "ok flow@devkit ${HEAD12}"
cd "$SPACED" || exit 1

# A21: CLAUDE_CONFIG_DIR not set -> $HOME/.claude.
mkdir -p "$HOME/.claude"
mv "$CLAUDE_CONFIG_DIR/plugins" "$HOME/.claude/plugins"
OUT="$(env -u CLAUDE_CONFIG_DIR "$SCRIPT" --status 2>"$TMPROOT/stderr")"
RC=$?
ERR="$(cat "$TMPROOT/stderr")"
expect "A21 CLAUDE_CONFIG_DIR not set -> reads HOME/.claude" 0 "ok flow@devkit ${HEAD12}"
run --status
expect "A21 CLAUDE_CONFIG_DIR set -> reads only that folder" 1 \
    "missing flow@devkit  fix: claude plugin install flow@devkit --scope project"
mv "$HOME/.claude/plugins" "$CLAUDE_CONFIG_DIR/plugins"

# A23: read-only.
snapshot() {
    {
        find "$CLAUDE_CONFIG_DIR" "$HOME" "$SPACED/.claude" -type f -exec cksum {} \; | LC_ALL=C sort
        git -C "$SPACED" status --porcelain
        git -C "$MKT" status --porcelain
        git -C "$MKT" rev-parse HEAD
    }
}
BEFORE="$(snapshot)"
run --status --running "$TMPROOT/cache/devkit/flow/${OLD12}"
AFTER="$(snapshot)"
if [ "$BEFORE" = "$AFTER" ]; then
    pass "A23 read-only: files and git status are the same"
else
    fail "A23 read-only: files and git status are the same" "before: [$BEFORE]" "after:  [$AFTER]"
fi

# A24: never exit 10, and the script is safe for bash 3.2.
case " $ALL_RCS " in
    *" 10 "*) fail "A24 no case exits 10" "exit codes:$ALL_RCS" ;;
    *) pass "A24 no case exits 10" ;;
esac
if bash -n "$SCRIPT" && ! grep -nE 'mapfile|readarray|declare -A|stat -c|sed -i( |$)' "$SCRIPT"; then
    pass "A24 bash -n, no bash-4-only or GNU-only forms"
else
    fail "A24 bash -n, no bash-4-only or GNU-only forms"
fi

harness_report
