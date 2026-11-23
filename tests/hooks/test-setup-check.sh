#!/bin/bash
#
# Tests for plugins/flow/hooks/setup-check.sh, the SessionStart check. It
# must print nothing when the repo is set up, one line when it is not, and
# always exit 0, so it never blocks a session.
#
# HERMETIC: each case runs in a throwaway git repo (mktemp -d). The hook
# calls flow-plugins, so CLAUDE_CONFIG_DIR and HOME point into $TMPROOT. The
# plugin installs on the machine never change a result.
#
# Usage: bash tests/hooks/test-setup-check.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The project.md lines hold literal backticks, so single quotes are on purpose.
# shellcheck disable=SC2016
set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REAL_REPO/plugins/flow/hooks/setup-check.sh"
export CLAUDE_PLUGIN_ROOT="$REAL_REPO/plugins/flow"

TMPROOT="$(cd -P "$(mktemp -d)" && pwd)" || exit 1
export HOME="$TMPROOT/home"
export CLAUDE_CONFIG_DIR="$TMPROOT/cfg"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/plugins"
PLUGINS="$CLAUDE_CONFIG_DIR/plugins"

# check <label> <want-stdout>
check() {
    local out rc
    out="$("$BASH" "$HOOK" </dev/null 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then
        pass "$1"
    else
        fail "$1" "exit: $rc (want 0)" "output: [$out]" "want:   [$2]"
    fi
}

mkdir -p "$TMPROOT/nogit"
cd "$TMPROOT/nogit" || exit 1
check "outside a git repo -> silent" ""

REPO="$TMPROOT/repo"
git init -q "$REPO" >/dev/null 2>&1
cd "$REPO" || exit 1
check "nothing set up -> one line" \
    "flow: .claude/project.md is missing, CLAUDE.md is missing. Run /flow:setup."

project_md_write "$REPO" 'test: `make test`' 'lint: `make lint`'
printf '# Project\n' > CLAUDE.md
check "no block -> one line" "flow: the CLAUDE.md flow block is missing. Run /flow:setup."

"$CLAUDE_PLUGIN_ROOT/bin/flow-claude-block" --apply >/dev/null
check "set up -> silent" ""

sed -i.bak -E 's/^<!-- flow:begin rev [0-9]+ -->$/<!-- flow:begin rev 0 -->/' CLAUDE.md && rm -f CLAUDE.md.bak
check "old block -> one line" \
    "flow: the CLAUDE.md flow block is old (rev 0, current rev $(sed -nE '1s/^<!-- flow:begin rev ([0-9]+) -->$/\1/p' "$CLAUDE_PLUGIN_ROOT/templates/claude-block.md")). Run /flow:setup."

# The cases below give the repo enabled plugins and fake install records.
gitc() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
MKT="$TMPROOT/marketplace"
mkdir -p "$MKT/.claude-plugin"
printf '{"name": "devkit", "plugins": [{"name": "flow", "source": "./plugins/flow"}]}\n' \
    > "$MKT/.claude-plugin/marketplace.json"
git init -q "$MKT" >/dev/null 2>&1
gitc -C "$MKT" add -A >/dev/null
gitc -C "$MKT" commit -q -m one >/dev/null
HEAD12="$(git -C "$MKT" rev-parse HEAD | cut -c1-12)"
OLD12="aaaaaaaaaaaa"
jq -n --arg l "$MKT" '{devkit: {installLocation: $l}}' > "$PLUGINS/known_marketplaces.json"
mkdir -p .claude
printf '{"enabledPlugins": {"flow@devkit": true}}\n' > .claude/settings.json

# write_install <version>: a project install of flow@devkit for $REPO.
write_install() {
    jq -n --arg p "$REPO" --arg v "$1" \
        '{version: 2, plugins: {"flow@devkit": [{scope: "project", projectPath: $p, version: $v}]}}' \
        > "$PLUGINS/installed_plugins.json"
}

"$CLAUDE_PLUGIN_ROOT/bin/flow-claude-block" --apply >/dev/null
FIX="claude plugin update flow@devkit --scope project"

write_install "$OLD12"
check "B25 stale plugin -> one line with the update command" \
    "flow: plugin flow@devkit is old (installed ${OLD12}, expected ${HEAD12}, fix: ${FIX}). Run /flow:setup. Restart the session after a plugin fix."

write_install "$HEAD12"
check "B26 all plugins current -> silent" ""

# An installed flow runs from .../cache/<mkt>/<plugin>/<sha12>.
CACHE_ROOT="$TMPROOT/cache/devkit/flow/${OLD12}"
mkdir -p "$(dirname "$CACHE_ROOT")"
cp -R "$REAL_REPO/plugins/flow" "$CACHE_ROOT"
CLAUDE_PLUGIN_ROOT="$CACHE_ROOT" check "B27 running flow stale, install current -> restart only" \
    "flow: the running plugin flow@devkit is old (running ${OLD12}, expected ${HEAD12}, fix: restart the session)."
write_install "$OLD12"
CLAUDE_PLUGIN_ROOT="$CACHE_ROOT" check "B27 running flow stale, install stale -> update command" \
    "flow: plugin flow@devkit is old (installed ${OLD12}, expected ${HEAD12}, fix: ${FIX}), the running plugin flow@devkit is old (running ${OLD12}, expected ${HEAD12}, fix: ${FIX}). Run /flow:setup. Restart the session after a plugin fix."

# B31: no jq on PATH. flow-plugins exits 2, so the hook says nothing about
# plugins. The install is stale, so with jq the hook prints a line.
NOJQ="$TMPROOT/nojq-bin"
mkdir -p "$NOJQ"
for t in git basename dirname cat sed awk grep head tail mktemp diff mv rm cut tr wc; do
    ln -s "$(command -v "$t")" "$NOJQ/$t"
done
PATH="$NOJQ" check "B31 no jq -> silent about plugins, exit 0" ""

# B32: git cannot read the .git of the marketplace checkout. flow-plugins
# exits 2, so the hook says nothing about plugins.
mv "$MKT/.git" "$TMPROOT/mkt-git"
printf 'gitdir: %s\n' "$TMPROOT/no-such-dir" > "$MKT/.git"
check "B32 marketplace .git that git cannot read -> silent, exit 0" ""
rm -f "$MKT/.git"
mv "$TMPROOT/mkt-git" "$MKT/.git"

printf '{ not json' > "$PLUGINS/installed_plugins.json"
check "B28 bad JSON -> silent, exit 0" ""
write_install "$OLD12"

rm -f "$CACHE_ROOT/bin/flow-plugins"
CLAUDE_PLUGIN_ROOT="$CACHE_ROOT" check "B29 no flow-plugins in the plugin root -> silent" ""

rm -f .claude/project.md
check "B30 stale plugin and no project.md -> exact one line" \
    "flow: .claude/project.md is missing, plugin flow@devkit is old (installed ${OLD12}, expected ${HEAD12}, fix: ${FIX}). Run /flow:setup. Restart the session after a plugin fix."

rm -f "$PLUGINS/installed_plugins.json"
check "B30 no project.md, missing plugin -> install command" \
    "flow: .claude/project.md is missing, plugin flow@devkit is not installed (fix: claude plugin install flow@devkit --scope project). Run /flow:setup. Restart the session after a plugin fix."

harness_report
