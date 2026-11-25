#!/bin/bash
#
# Tests that the flow commands and scripts handle release tags with the v*
# filter only. A `git fetch --tags` fails with "would clobber existing tag"
# when a moving tag such as skills-latest moved on origin. A `git describe
# --tags` with no --match 'v*' can return that moving tag as the last
# release.
#
# - No file in plugins/flow/commands/*.md, plugins/flow/bin/* or
#   plugins/flow/bin/lib/*.sh has a `git fetch` line with --tags.
# - plan-milestone.md, start-milestone.md, release-milestone.md and
#   start-issue.md contain the refspec '+refs/tags/v*:refs/tags/v*'.
# - Each `git describe --tags` has --match 'v*'. A quoted message that names
#   the failed call (`--abbrev=0 failed`) is text, not a call.
#
# Usage: bash tests/commands/test-release-tag-refs.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMPROOT="$(mktemp -d)" || exit 1

# The refspec has a literal * on purpose.
REFSPEC="'+refs/tags/v*:refs/tags/v*'"

# fetch_tags_lines <file>...: print each "file:line:text" that fetches --tags.
fetch_tags_lines() {
    grep -nHE 'git fetch.*--tags' "$@"
}

# bad_describe_lines <file>...: print each "file:line:text" that has
# `git describe --tags` with no --match 'v*', not counting a quoted failure
# message.
bad_describe_lines() {
    grep -nHE 'git describe --tags' "$@" \
        | grep -vF -e '--abbrev=0 failed' \
        | grep -vF -e "--match 'v*'" -e '--match "v*"'
}

# check_tree <root>
# Prints one reason for each broken rule. Returns 1 when any rule is broken.
check_tree() {
    local root="$1" bad=0 out f
    local files=("$root"/plugins/flow/commands/*.md "$root"/plugins/flow/bin/* "$root"/plugins/flow/bin/lib/*.sh)
    local regular=()
    for f in "${files[@]}"; do
        [ -f "$f" ] && regular+=("$f")
    done
    if [ "${#regular[@]}" -lt 10 ]; then
        echo "found only ${#regular[@]} files under $root"
        return 1
    fi
    out="$(fetch_tags_lines "${regular[@]}")"
    if [ -n "$out" ]; then
        echo "git fetch with --tags:"
        echo "$out"
        bad=1
    fi
    for f in plan-milestone start-milestone release-milestone start-issue; do
        if ! grep -qF -- "$REFSPEC" "$root/plugins/flow/commands/$f.md"; then
            echo "$f.md has no $REFSPEC"
            bad=1
        fi
    done
    out="$(bad_describe_lines "${regular[@]}")"
    if [ -n "$out" ]; then
        echo "git describe --tags with no --match 'v*':"
        echo "$out"
        bad=1
    fi
    return "$bad"
}

if WHY="$(check_tree "$REAL_REPO")"; then
    pass "no fetch with --tags, refspec in the four commands, describe has --match 'v*'"
else
    fail "release tag handling" "$WHY"
fi

# The describe check must see at least one real call, or it proves nothing.
if grep -qE "git describe --tags .*--match 'v\*'" \
    "$REAL_REPO/plugins/flow/bin/flow-check-version-newer" "$REAL_REPO/plugins/flow/commands/start-issue.md"; then
    pass "the describe check has real calls to look at"
else
    fail "the describe check has real calls to look at"
fi

# The quoted failure messages must not count as calls.
if grep -qF -- '--abbrev=0 failed' "$REAL_REPO/plugins/flow/commands/plan-milestone.md" \
    && [ -z "$(bad_describe_lines "$REAL_REPO/plugins/flow/commands/plan-milestone.md" "$REAL_REPO/plugins/flow/bin/flow-check-version-newer")" ]; then
    pass "a quoted 'git describe --tags --abbrev=0 failed' message is not a call"
else
    fail "a quoted 'git describe --tags --abbrev=0 failed' message is not a call"
fi

# --- Negative controls: a changed copy must fail --------------------------
# make_copy <name>: copy the checked files to $TMPROOT/<name>; prints the dir.
make_copy() {
    local d="$TMPROOT/$1"
    mkdir -p "$d/plugins/flow/commands" "$d/plugins/flow/bin" || return 1
    cp "$REAL_REPO"/plugins/flow/commands/*.md "$d/plugins/flow/commands/" || return 1
    cp -R "$REAL_REPO"/plugins/flow/bin/. "$d/plugins/flow/bin/" || return 1
    echo "$d"
}

# expect_broken <label> <dir>
expect_broken() {
    local out
    if out="$(check_tree "$2")"; then
        fail "control: $1 fails the check"
    else
        pass "control: $1 fails the check ($(printf '%s' "$out" | head -n 1))"
    fi
}

# edit_copy <dir> <file-under-plugins/flow> <sed-expression>
# Applies the edit, and fails the test when the edit changed nothing.
edit_copy() {
    local f="$1/plugins/flow/$2" before
    before="$(cat "$f")"
    sed "$3" "$f" > "$f.new" && mv "$f.new" "$f"
    if [ "$before" = "$(cat "$f")" ]; then
        fail "control edit changed $2" "$3"
    fi
}

D="$(make_copy fetch-tags)" || exit 1
edit_copy "$D" commands/release-milestone.md "s#git fetch origin '+refs/tags/v\*:refs/tags/v\*'#git fetch origin --tags#"
expect_broken "git fetch --tags in a command" "$D"

D="$(make_copy fetch-tags-script)" || exit 1
edit_copy "$D" bin/flow-release-hotfix "s#origin main '+refs/tags/v\*:refs/tags/v\*'#origin main --tags#"
expect_broken "git fetch --tags in a script" "$D"

D="$(make_copy no-refspec)" || exit 1
edit_copy "$D" commands/start-milestone.md "s#'+refs/tags/v\*:refs/tags/v\*'#'+refs/tags/*:refs/tags/*'#"
expect_broken "refspec missing from start-milestone.md" "$D"

D="$(make_copy describe-command)" || exit 1
edit_copy "$D" commands/start-issue.md "s# --match 'v\*'##"
expect_broken "git describe with no --match in a command" "$D"

D="$(make_copy describe-script)" || exit 1
edit_copy "$D" bin/flow-check-version-newer "s#git describe --tags --abbrev=0 --match 'v\*' 2>#git describe --tags --abbrev=0 2>#"
expect_broken "git describe with no --match in a script" "$D"

harness_report
