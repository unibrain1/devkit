#!/bin/bash
#
# PreToolUse hook (Read, Edit, MultiEdit, Write, NotebookEdit, Grep) from
# the devkit web-app template (docs/families.md, Family W). It stops Claude
# from reading or changing an .env file, because a web app keeps its
# database and API credentials there. Wrangler (Cloudflare) keeps local
# secrets in .dev.vars.
#
# Blocks: a file named .env, .env.<anything>, .dev.vars, or
# .dev.vars.<anything>, in any folder, in any letter case. A
# case-insensitive file system (macOS) opens .env for .ENV.
# Allows: a name that ends in .example or .sample, and each other file.
# Limits: it does not stop a Bash command such as `cat .env`, or a Grep
# over a folder with an .env glob. It does not resolve symlinks.
#
# Input: the hook JSON on stdin. Reads .tool_input.file_path, or
# .tool_input.notebook_path (NotebookEdit), or .tool_input.path (Grep).
# Exit codes:
#   0  The tool call can continue.
#   2  Blocked. The reason is on stderr, and Claude Code shows it to Claude.

if ! command -v jq >/dev/null 2>&1; then
    # Block the call. A missing jq must not turn the guard off in silence.
    echo "BLOCK: block-env.sh needs jq to read the file path. Install jq." >&2
    exit 2
fi

# -n with input: empty stdin is an error, not an empty path.
if ! file="$(jq -nr 'input | .tool_input
        | .file_path // .notebook_path // .path // empty' 2>/dev/null)"; then
    echo "BLOCK: block-env.sh cannot read the hook input as JSON." >&2
    exit 2
fi
[ -n "$file" ] || exit 0

# nocasematch is a bash builtin option, so no outside tool can fail here.
shopt -s nocasematch
case "${file##*/}" in
    *.example | *.sample) exit 0 ;;
    .env | .env.* | .dev.vars | .dev.vars.*)
        echo "BLOCK: do not read or change .env or .dev.vars files. They hold secrets." >&2
        exit 2
        ;;
esac
exit 0
