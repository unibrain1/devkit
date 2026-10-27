#!/bin/bash
#
# Checks each skill in plugins/brain/skills/ against the claude.ai upload
# rules, then zips it to dist/<skill>.zip. Jim uploads these zips at
# claude.ai -> Settings -> Customize -> Skills, so the desktop and phone apps
# get the skills. The checks run here because claude.ai refuses a bad upload
# only after the upload, for example an XML tag in the description.
#
# Usage: .github/scripts/package-skills.sh [--check] [skills-dir] [out-dir]
#   --check     Check only. Write no zip.
#   skills-dir  Default: plugins/brain/skills
#   out-dir     Default: dist
#
# Exit codes:
#   0  Every skill passed (and, without --check, is zipped).
#   1  One or more skills failed a check. Each failure is printed on stderr.
#   2  Usage error, or the skills dir does not exist.

set -euo pipefail

check_only=0
if [ "${1:-}" = "--check" ]; then
    check_only=1
    shift
fi
skills_dir="${1:-plugins/brain/skills}"
out_dir="${2:-dist}"

if [ ! -d "$skills_dir" ]; then
    echo "package-skills: '${skills_dir}' is not a directory." >&2
    exit 2
fi

# frontmatter_value <file> <key>: prints the value of a one-line key from the
# YAML frontmatter, without surrounding quotes. Prints nothing if absent.
frontmatter_value() {
    awk -v key="$2" '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        NR > 1 && index($0, key ":") == 1 {
            v = substr($0, length(key) + 2)
            sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
            print v; exit
        }' "$1"
}

bad=0
count=0
for dir in "$skills_dir"/*/; do
    [ -d "$dir" ] || continue
    skill="$(basename "$dir")"
    file="${dir}SKILL.md"
    count=$((count + 1))

    if [ ! -f "$file" ]; then
        echo "${skill}: no SKILL.md." >&2
        bad=$((bad + 1))
        continue
    fi

    name="$(frontmatter_value "$file" name)"
    description="$(frontmatter_value "$file" description)"
    failed=0
    if [ "$name" != "$skill" ]; then
        echo "${skill}: frontmatter name '${name}' is not the folder name." >&2
        failed=1
    fi
    if ! printf '%s' "$name" | grep -qE '^[a-z0-9-]{1,64}$'; then
        echo "${skill}: name must be 1 to 64 lowercase letters, digits, or hyphens." >&2
        failed=1
    fi
    if [ -z "$description" ]; then
        echo "${skill}: no description." >&2
        failed=1
    fi
    if [ "${#description}" -gt 1024 ]; then
        echo "${skill}: description has ${#description} characters. The limit is 1024." >&2
        failed=1
    fi
    case "$description" in
        *"<"*|*">"*)
            echo "${skill}: description has '<' or '>'. claude.ai refuses XML tags." >&2
            failed=1
            ;;
    esac
    if [ "$failed" -ne 0 ]; then
        bad=$((bad + 1))
        continue
    fi

    if [ "$check_only" -eq 0 ]; then
        mkdir -p "$out_dir"
        zip_path="$(cd "$out_dir" && pwd)/${skill}.zip"
        rm -f "$zip_path"
        (cd "$skills_dir" && zip -r -X -q "$zip_path" "$skill" -x '*.DS_Store')
        echo "$zip_path"
    fi
done

if [ "$count" -eq 0 ]; then
    echo "package-skills: no skill folders in '${skills_dir}'." >&2
    exit 2
fi
[ "$bad" -eq 0 ] || exit 1
