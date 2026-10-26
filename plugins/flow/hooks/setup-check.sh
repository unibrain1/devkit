#!/bin/bash
#
# SessionStart hook. Says "Run /flow:setup" when this repo has no
# .claude/project.md or its CLAUDE.md flow block is old or missing. When both
# are correct, it prints nothing, so a normal session gets no extra context.
#
# It never blocks a session: every path exits 0.

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Outside a git repo, flow has nothing to set up.
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

problems=()
if ! "${root}/bin/flow-project-fact" --file >/dev/null 2>&1 \
    || [ ! -f "$("${root}/bin/flow-project-fact" --file 2>/dev/null)" ]; then
    problems+=(".claude/project.md is missing")
fi

if ! status="$("${root}/bin/flow-claude-block" --status 2>&1)"; then
    case "$status" in
        "no CLAUDE.md") problems+=("CLAUDE.md is missing") ;;
        *) problems+=("the CLAUDE.md flow block is ${status}") ;;
    esac
fi

if [ "${#problems[@]}" -gt 0 ]; then
    joined="$(printf '%s, ' "${problems[@]}")"
    echo "flow: ${joined%, }. Run /flow:setup."
fi
exit 0
