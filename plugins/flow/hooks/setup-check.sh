#!/bin/bash
#
# SessionStart hook. Says "Run /flow:setup" when this repo has no
# .claude/project.md, its CLAUDE.md flow block is old or missing, or a plugin
# that the repo enables is missing or old (flow-plugins). When only the
# running plugin is old and its install is current, it says to restart the
# session. When all are correct, it prints nothing, so a normal session gets
# no extra context.
#
# It never blocks a session: every path exits 0.

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Outside a git repo, flow has nothing to set up.
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

problems=()
f="$("${root}/bin/flow-project-fact" --file 2>/dev/null)" && [ -f "$f" ] \
    || problems+=(".claude/project.md is missing")

if ! status="$("${root}/bin/flow-claude-block" --status 2>&1)"; then
    case "$status" in
        "no CLAUDE.md") problems+=("CLAUDE.md is missing") ;;
        *) problems+=("the CLAUDE.md flow block is ${status}") ;;
    esac
fi

# A running plugin that is old while its install is current needs only a
# restart. /flow:setup has nothing to do for it, so the line does not name
# /flow:setup when that is the only problem.
setup_fix=0
[ "${#problems[@]}" -gt 0 ] && setup_fix=1

# Exit 2 from flow-plugins (no jq, bad JSON) adds nothing. The hook only
# reports a plugin problem that it is sure of.
plugin_fix=0
if [ -x "${root}/bin/flow-plugins" ]; then
    plugins="$("${root}/bin/flow-plugins" --status --running "$root" 2>/dev/null)"
    if [ "$?" -eq 1 ]; then
        while IFS= read -r line; do
            fix="${line#*  fix: }"
            read -r kind key a b <<LINE
${line%%  fix: *}
LINE
            case "$kind" in
                missing) problems+=("plugin ${key} is not installed (fix: ${fix})") ;;
                stale) problems+=("plugin ${key} is old (installed ${a}, expected ${b}, fix: ${fix})") ;;
                stale-running)
                    problems+=("the running plugin ${key} is old (running ${a}, expected ${b}, fix: ${fix})")
                    [ "$fix" = "restart the session" ] && continue
                    ;;
                *) continue ;;
            esac
            plugin_fix=1
        done <<EOF
$plugins
EOF
    fi
fi

if [ "${#problems[@]}" -gt 0 ]; then
    joined="$(printf '%s, ' "${problems[@]}")"
    if [ "$plugin_fix" -eq 1 ]; then
        echo "flow: ${joined%, }. Run /flow:setup. Restart the session after a plugin fix."
    elif [ "$setup_fix" -eq 1 ]; then
        echo "flow: ${joined%, }. Run /flow:setup."
    else
        echo "flow: ${joined%, }."
    fi
fi
exit 0
