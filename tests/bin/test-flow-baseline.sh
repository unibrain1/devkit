#!/bin/bash
#
# Tests for plugins/flow/bin/flow-baseline: --status and --apply of the
# every-repo baseline files. --apply must never replace a file, write
# through a symbolic link, or write outside the repo.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d). The cases
# use a fake plugin tree with fixture files, not the real baseline content.
# One case checks that the real script finds the real baseline folder.
#
# Usage: bash tests/bin/test-flow-baseline.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

# The write-failure case makes a folder read-only. Make all of $TMPROOT
# writable again, so rm -rf can remove it.
# shellcheck disable=SC2329 # called only through the EXIT trap
cleanup() {
    cd / || true
    if [ -n "${TMPROOT:-}" ]; then
        chmod -R u+rwx "$TMPROOT" 2>/dev/null
        rm -rf "$TMPROOT"
    fi
}

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_SCRIPT="$REAL_REPO/plugins/flow/bin/flow-baseline"
REAL_BASELINE="$REAL_REPO/plugins/flow/templates/baseline"

TMPROOT="$(cd -P "$(mktemp -d)" && pwd)" || exit 1
PLUGIN="$TMPROOT/plugin"
SCRIPT="$PLUGIN/bin/flow-baseline"
TPL="$PLUGIN/templates/baseline"
OUTSIDE="$TMPROOT/outside"

mkdir -p "$PLUGIN/bin" "$TPL/.github/workflows" "$OUTSIDE"
cp "$REAL_SCRIPT" "$SCRIPT"
chmod 755 "$SCRIPT"
printf 'repos: []\n' > "$TPL/.pre-commit-config.yaml"
printf 'version: 2\n' > "$TPL/.github/dependabot.yml"
printf 'name: Claude Code Review\n' > "$TPL/.github/workflows/claude-code-review.yml"
printf 'name: Claude\n' > "$TPL/.github/workflows/claude.yml"
# No trailing newline: the copy must keep the bytes as they are.
printf 'name: Secrets scan' > "$TPL/.github/workflows/secrets-scan.yml"

ALL=".github/dependabot.yml
.github/workflows/claude-code-review.yml
.github/workflows/claude.yml
.github/workflows/secrets-scan.yml
.pre-commit-config.yaml"

# new_repo <name>: make an empty git repo in $TMPROOT and cd into it.
new_repo() {
    REPO="$TMPROOT/$1"
    git init -q "$REPO" >/dev/null 2>&1
    cd "$REPO" || exit 1
}

# run <script> <args...>: sets OUT, ERR, RC.
run() {
    local s="$1"
    shift
    OUT="$("$s" "$@" 2>"$TMPROOT/stderr")"
    RC=$?
    ERR="$(cat "$TMPROOT/stderr")"
}

# expect_rc <label> <want-rc>
expect_rc() {
    if [ "$RC" -eq "$2" ]; then
        pass "$1"
    else
        fail "$1" "exit: $RC (want $2)" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
}

# expect_status <label> <want-rc> <want-stdout>
expect_status() {
    run "$SCRIPT" --status
    if [ "$RC" -eq "$2" ] && [ "$OUT" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "exit: $RC (want $2)" "stdout: [$OUT]" "want:   [$3]" "stderr: [$ERR]"
    fi
}

# lines_with <word>: the $ALL paths, each with "<word> " in front.
lines_with() {
    printf '%s\n' "$ALL" | sed "s|^|$1 |"
}

# tree_files: all files and links in the current repo, except .git.
tree_files() {
    find . -path ./.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort
}

copy_all() {
    local rel
    while IFS= read -r rel; do
        mkdir -p "$(dirname "$rel")"
        cp "$TPL/$rel" "$rel"
    done <<EOF
$ALL
EOF
}

# --- C1: usage -----------------------------------------------------------

new_repo usage
for args in "" "--bogus" "--status --apply" "--status extra" "--apply"; do
    # shellcheck disable=SC2086 # split the arguments on purpose
    run "$SCRIPT" $args
    expect_rc "usage: [${args}] -> 2" 2
done
if [ -z "$(tree_files)" ]; then
    pass "usage errors write no file"
else
    fail "usage errors write no file" "$(tree_files)"
fi

# --- C2: not a git repo --------------------------------------------------

mkdir -p "$TMPROOT/nogit"
cd "$TMPROOT/nogit" || exit 1
run "$SCRIPT" --status
expect_rc "status outside a git repo -> 2" 2
run "$SCRIPT" --apply .pre-commit-config.yaml
expect_rc "apply outside a git repo -> 2" 2
if [ -z "$(find . -mindepth 1 -print)" ]; then
    pass "outside a git repo, no file is written"
else
    fail "outside a git repo, no file is written" "$(find . -mindepth 1 -print)"
fi

# --- C3, C4: status ------------------------------------------------------

new_repo status
expect_status "empty repo (no commits): five missing, exit 1" 1 "$(lines_with missing)"
if [ -z "$(git status --porcelain)" ]; then
    pass "status writes nothing (git status is clean)"
else
    fail "status writes nothing (git status is clean)" "$(git status --porcelain)"
fi

mkdir -p sub/dir
cd sub/dir || exit 1
expect_status "status from a subfolder prints repo-relative paths" 1 "$(lines_with missing)"
cd "$REPO" || exit 1

copy_all
expect_status "all copied: all same, exit 0" 0 "$(lines_with same)"

printf 'edited\n' >> .github/workflows/claude.yml
expect_status "one edited: different, exit 0" 0 "$(lines_with same | sed 's|^same \.github/workflows/claude\.yml$|different .github/workflows/claude.yml|')"

rm .github/dependabot.yml
run "$SCRIPT" --status
if [ "$RC" -eq 1 ] \
    && printf '%s\n' "$OUT" | grep -qx 'missing .github/dependabot.yml' \
    && printf '%s\n' "$OUT" | grep -qx 'different .github/workflows/claude.yml'; then
    pass "missing and different together: exit 1"
else
    fail "missing and different together: exit 1" "exit: $RC" "stdout: [$OUT]"
fi

# --- C5: status and links ------------------------------------------------

new_repo statuslinks
copy_all
cp "$TPL/.pre-commit-config.yaml" "$OUTSIDE/same-content"
rm .pre-commit-config.yaml
ln -s "$OUTSIDE/same-content" .pre-commit-config.yaml
ln -s "$OUTSIDE/no-such-file" .github/dependabot.yml.tmp
rm .github/dependabot.yml
mv .github/dependabot.yml.tmp .github/dependabot.yml
run "$SCRIPT" --status
if [ "$RC" -eq 0 ] \
    && printf '%s\n' "$OUT" | grep -qx 'different .pre-commit-config.yaml' \
    && printf '%s\n' "$OUT" | grep -qx 'different .github/dependabot.yml'; then
    pass "status: a link (same content, or broken) is different, exit 0"
else
    fail "status: a link (same content, or broken) is different, exit 0" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
fi

new_repo statusdirlink
mkdir -p "$OUTSIDE/gh"
ln -s "$OUTSIDE/gh" .github
run "$SCRIPT" --status
if [ "$RC" -eq 1 ] \
    && [ "$(printf '%s\n' "$OUT" | grep -c '^different \.github/')" -eq 4 ] \
    && printf '%s\n' "$OUT" | grep -qx 'missing .pre-commit-config.yaml'; then
    pass "status: files under a .github folder link are different"
else
    fail "status: files under a .github folder link are different" "exit: $RC" "stdout: [$OUT]"
fi

new_repo statusblocked
printf 'a file\n' > .github
mkdir .pre-commit-config.yaml
run "$SCRIPT" --status
if [ "$RC" -eq 0 ] && [ "$OUT" = "$(lines_with different)" ]; then
    pass "status: a file at .github and a folder at a file path are different"
else
    fail "status: a file at .github and a folder at a file path are different" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
fi

# A root user can read a mode-000 file, so the case cannot run as root.
if [ "$IS_ROOT" -eq 1 ]; then
    pass "status: unreadable file: skipped as root"
else
    new_repo statusunreadable
    copy_all
    chmod 000 .pre-commit-config.yaml
    run "$SCRIPT" --status
    chmod 644 .pre-commit-config.yaml
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qF "cannot compare $REPO/.pre-commit-config.yaml"; then
        pass "status: unreadable repo file -> 2, stderr names the file"
    else
        fail "status: unreadable repo file -> 2" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
    fi
fi

# --- C6: apply -----------------------------------------------------------

new_repo applyone
run "$SCRIPT" --apply .github/workflows/secrets-scan.yml
if [ "$RC" -eq 0 ] && cmp -s "$TPL/.github/workflows/secrets-scan.yml" .github/workflows/secrets-scan.yml \
    && [ "$(tree_files)" = "./.github/workflows/secrets-scan.yml" ]; then
    pass "apply one file: byte-equal (no trailing newline kept), parents made, no other file"
else
    fail "apply one file" "exit: $RC" "stderr: [$ERR]" "files: $(tree_files)"
fi

new_repo applymany
# The apply calls run in a repo with a commit and a staged file, so the
# index check (C12) uses the same runs.
printf 'x\n' > committed.txt
git add committed.txt
git -c user.name=t -c user.email=t@example.com commit -q -m init
printf 'y\n' > staged.txt
git add staged.txt
cp .git/index "$TMPROOT/index.before"
# shellcheck disable=SC2086 # the paths have no spaces
run "$SCRIPT" --apply $ALL
cp .git/index "$TMPROOT/index.after"
ok=1
while IFS= read -r rel; do
    cmp -s "$TPL/$rel" "$rel" || ok=0
    [ -x "$rel" ] && ok=0
    [ -n "$(find "$rel" -type f -perm 644)" ] || ok=0
done <<EOF
$ALL
EOF
if [ "$RC" -eq 0 ] && [ "$ok" -eq 1 ]; then
    pass "apply all files: each byte-equal, mode 0644, not executable"
else
    fail "apply all files" "exit: $RC" "stderr: [$ERR]" "$(ls -la .github .github/workflows .pre-commit-config.yaml 2>&1)"
fi
if cmp -s "$TMPROOT/index.before" "$TMPROOT/index.after"; then
    pass "apply does not change the git index"
else
    fail "apply does not change the git index"
fi
if [ -z "$(git diff --cached --name-only -- .github .pre-commit-config.yaml)" ]; then
    pass "applied files are not staged"
else
    fail "applied files are not staged" "$(git diff --cached --name-only)"
fi
if [ -z "$(find . -name '.flow-baseline.*' -print)" ]; then
    pass "apply leaves no temp file"
else
    fail "apply leaves no temp file" "$(find . -name '.flow-baseline.*' -print)"
fi
expect_status "status after apply of all: all same" 0 "$(lines_with same)"

# --- C7: apply of an existing file ---------------------------------------

new_repo applyexists
mkdir -p .github
printf 'mine\n' > .github/dependabot.yml
cp "$TPL/.pre-commit-config.yaml" .pre-commit-config.yaml
run "$SCRIPT" --apply .github/dependabot.yml
expect_rc "apply of an existing different file -> 1" 1
if [ "$(cat .github/dependabot.yml)" = "mine" ]; then
    pass "existing different file does not change"
else
    fail "existing different file does not change" "content: [$(cat .github/dependabot.yml)]"
fi
cp -p .pre-commit-config.yaml "$TMPROOT/precommit.before"
run "$SCRIPT" --apply .pre-commit-config.yaml
expect_rc "apply of an existing same file -> 1" 1
run "$SCRIPT" --apply .github/workflows/claude.yml .github/dependabot.yml
expect_rc "apply of one missing and one existing -> 1" 1
if [ ! -e .github/workflows/claude.yml ] && [ "$(cat .github/dependabot.yml)" = "mine" ]; then
    pass "one existing file in the list: nothing is written"
else
    fail "one existing file in the list: nothing is written" "$(tree_files)"
fi

new_repo applyblocked
printf 'a file\n' > .github
run "$SCRIPT" --apply .github/dependabot.yml
expect_rc "apply when a file blocks the parent folder -> 1" 1
if [ "$(cat .github)" = "a file" ]; then
    pass "blocking file does not change"
else
    fail "blocking file does not change"
fi

# A failed write after a first write exits 3 and names the written files.
# A root user can write in a mode-555 folder, so the case cannot run as root.
if [ "$IS_ROOT" -eq 1 ]; then
    pass "apply: write failure: skipped as root"
else
    new_repo applywritefail
    mkdir .github
    chmod 555 .github
    run "$SCRIPT" --apply .pre-commit-config.yaml .github/dependabot.yml
    chmod 755 .github
    if [ "$RC" -eq 3 ] \
        && printf '%s' "$ERR" | grep -qF "could not write .github/dependabot.yml. Wrote: .pre-commit-config.yaml." \
        && cmp -s "$TPL/.pre-commit-config.yaml" .pre-commit-config.yaml \
        && [ ! -e .github/dependabot.yml ]; then
        pass "apply: write failure after one write -> 3, stderr names the written file"
    else
        fail "apply: write failure after one write -> 3" "exit: $RC" "stderr: [$ERR]" "files: $(tree_files)"
    fi
    new_repo applywritefirst
    mkdir .github
    chmod 555 .github
    run "$SCRIPT" --apply .github/dependabot.yml
    chmod 755 .github
    if [ "$RC" -eq 3 ] && printf '%s' "$ERR" | grep -qF "Wrote: none."; then
        pass "apply: write failure on the first file -> 3, Wrote: none"
    else
        fail "apply: write failure on the first file -> 3" "exit: $RC" "stderr: [$ERR]"
    fi
fi

# --- C8: apply and links -------------------------------------------------

new_repo applyfilelink
ln -s "$OUTSIDE/written-through-link" .pre-commit-config.yaml
run "$SCRIPT" --apply .pre-commit-config.yaml
expect_rc "apply through a broken file link -> 2" 2
if [ ! -e "$OUTSIDE/written-through-link" ] && [ -L .pre-commit-config.yaml ]; then
    pass "file link: nothing is written outside the repo, the link stays"
else
    fail "file link: nothing is written outside the repo, the link stays" "$(ls -la "$OUTSIDE")"
fi

new_repo applydirlink
mkdir -p "$OUTSIDE/ghdir"
ln -s "$OUTSIDE/ghdir" .github
run "$SCRIPT" --apply .github/dependabot.yml
expect_rc "apply through a .github folder link -> 2" 2
run "$SCRIPT" --apply .github/workflows/claude.yml
expect_rc "apply through a .github folder link (nested file) -> 2" 2
if [ -z "$(find "$OUTSIDE/ghdir" -mindepth 1 -print)" ]; then
    pass ".github folder link: nothing is written outside the repo"
else
    fail ".github folder link: nothing is written outside the repo" "$(find "$OUTSIDE/ghdir" -mindepth 1 -print)"
fi

new_repo applysubdirlink
mkdir -p .github "$OUTSIDE/wfdir"
ln -s "$OUTSIDE/wfdir" .github/workflows
run "$SCRIPT" --apply .github/workflows/claude.yml
expect_rc "apply through a .github/workflows folder link -> 2" 2
if [ -z "$(find "$OUTSIDE/wfdir" -mindepth 1 -print)" ]; then
    pass "workflows folder link: nothing is written outside the repo"
else
    fail "workflows folder link: nothing is written outside the repo"
fi

# --- C9, C10: bad paths --------------------------------------------------

new_repo badpaths
for p in "not-in-baseline.txt" "../x" "/etc/x" ".github/../x" \
    "./.pre-commit-config.yaml" ".github//dependabot.yml" \
    ".github/workflows/../dependabot.yml" ".github" "" "templates/baseline/.pre-commit-config.yaml"; do
    run "$SCRIPT" --apply "$p"
    expect_rc "apply of bad path [${p}] -> 2" 2
done
run "$SCRIPT" --apply .pre-commit-config.yaml .pre-commit-config.yaml
expect_rc "apply of one path named two times -> 2" 2
run "$SCRIPT" --apply .pre-commit-config.yaml ../x
expect_rc "apply of one good and one bad path -> 2" 2
run "$SCRIPT" --apply .github/dependabot.yml .pre-commit-config.yaml not-in-baseline.txt
expect_rc "apply of two good paths and one bad path -> 2" 2
if [ -z "$(tree_files)" ] && [ ! -e "$TMPROOT/x" ] && [ ! -e "$TMPROOT/badpaths/x" ]; then
    pass "bad paths: nothing is written"
else
    fail "bad paths: nothing is written" "$(tree_files)"
fi

new_repo badwins
mkdir -p .github
printf 'mine\n' > .github/dependabot.yml
run "$SCRIPT" --apply .github/dependabot.yml ../x
expect_rc "apply of an existing file, then a bad path -> 2" 2
run "$SCRIPT" --apply ../x .github/dependabot.yml
expect_rc "apply of a bad path, then an existing file -> 2" 2

# --- C11: how the script is found ----------------------------------------

new_repo findscript
mkdir -p "$TMPROOT/linkbin" "$TMPROOT/rellink/bin"
ln -s "$SCRIPT" "$TMPROOT/linkbin/flow-baseline"
run "$TMPROOT/linkbin/flow-baseline" --status
if [ "$RC" -eq 1 ] && [ "$OUT" = "$(lines_with missing)" ]; then
    pass "works through an absolute symbolic link to the script"
else
    fail "works through an absolute symbolic link to the script" "exit: $RC" "stderr: [$ERR]"
fi
ln -s ../../plugin/bin/flow-baseline "$TMPROOT/rellink/bin/flow-baseline"
ln -s "$TMPROOT/rellink/bin/flow-baseline" "$TMPROOT/linkbin/chain"
run "$TMPROOT/linkbin/chain" --status
if [ "$RC" -eq 1 ] && [ "$OUT" = "$(lines_with missing)" ]; then
    pass "works through a chain of links with a relative link"
else
    fail "works through a chain of links with a relative link" "exit: $RC" "stderr: [$ERR]"
fi

SPACED="$TMPROOT/with space/plugin copy"
mkdir -p "$(dirname "$SPACED")"
cp -R "$PLUGIN" "$SPACED"
run "$SPACED/bin/flow-baseline" --apply .pre-commit-config.yaml
if [ "$RC" -eq 0 ] && cmp -s "$TPL/.pre-commit-config.yaml" .pre-commit-config.yaml; then
    pass "works from a copy of the plugin folder in a path with spaces"
else
    fail "works from a copy of the plugin folder in a path with spaces" "exit: $RC" "stderr: [$ERR]"
fi

NOTPL="$TMPROOT/notpl"
mkdir -p "$NOTPL/bin" "$NOTPL/templates"
cp "$SCRIPT" "$NOTPL/bin/flow-baseline"
new_repo notpl-repo
run "$NOTPL/bin/flow-baseline" --status
expect_rc "status with no baseline folder -> 2" 2
run "$NOTPL/bin/flow-baseline" --apply .pre-commit-config.yaml
expect_rc "apply with no baseline folder -> 2" 2
mkdir -p "$NOTPL/templates/baseline"
run "$NOTPL/bin/flow-baseline" --status
expect_rc "status with an empty baseline folder -> 2" 2
if [ -z "$(tree_files)" ]; then
    pass "no baseline folder: nothing is written"
else
    fail "no baseline folder: nothing is written" "$(tree_files)"
fi

DSPLUGIN="$TMPROOT/dsplugin"
cp -R "$PLUGIN" "$DSPLUGIN"
printf 'finder\n' > "$DSPLUGIN/templates/baseline/.DS_Store"
printf 'finder\n' > "$DSPLUGIN/templates/baseline/.github/.DS_Store"
new_repo dsstore
run "$DSPLUGIN/bin/flow-baseline" --status
if [ "$RC" -eq 1 ] && [ "$OUT" = "$(lines_with missing)" ]; then
    pass "a .DS_Store file in the baseline folder is not a baseline file"
else
    fail "a .DS_Store file in the baseline folder is not a baseline file" "exit: $RC" "stdout: [$OUT]"
fi

# --- Real baseline folder ------------------------------------------------

new_repo realtpl
real_count="$(cd "$REAL_BASELINE" 2>/dev/null && find . -type f | wc -l | tr -d ' ')"
run "$REAL_SCRIPT" --status
if [ "$RC" -eq 1 ] && [ "${real_count:-0}" -eq 5 ] \
    && [ "$(printf '%s\n' "$OUT" | grep -c '^missing ')" -eq 5 ]; then
    pass "real script finds the real baseline folder: five missing"
else
    fail "real script finds the real baseline folder: five missing" "files: ${real_count:-none}" "exit: $RC" "stdout: [$OUT]" "stderr: [$ERR]"
fi

harness_report
