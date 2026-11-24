#!/bin/bash
#
# Tests for the Family W templates: plugins/flow/templates/web-app/ (the files
# of a new web app, at the paths that the target repo uses) and
# web-app-hosts/ (the Deployment text of each host, not copied to the repo).
#
# Checks: the exact file sets, the baseline paths that web-app overrides, the
# pre-commit override content and its local hooks, YAML validity and the
# YAML placeholder form, the ci.yml triggers, permissions, and App job, the
# devkit pin rule, flow-project-check and the keys of project.md, the version
# forms in docs/families.md (run in a scratch git repo), settings.json
# against templates/settings.json and the .env hook entry, CLAUDE.md and the
# host files, placeholders, project facts, the .gitignore effect (git
# check-ignore), whitespace, and the CodeQL and Semgrep manual step.
#
# Override check: it is semantic, as in test-family-a.sh. Every repo entry of
# the baseline pre-commit file must be present, equal, in the parsed
# override, and the other top-level keys must be equal. A second check
# requires every line of the baseline file, comments too, in the override.
#
# YAML placeholder check: comments count too. After the ${{ ... }} GitHub
# expressions are removed, each line that holds "{{" must be one key with
# the quoted value "{{key}}" and nothing more. A placeholder in a comment
# fails, because the parser does not see it and a fill step can miss it.
#
# Each check has a break-it control. The control copies the inputs to a
# scratch folder, breaks one thing, runs this script on the copy, and
# expects the named check to fail. Set FAMILY_W_NO_CONTROLS=1 to skip them.
#
# Env overrides, for the controls on scratch copies:
#   TEMPLATES_DIR      the templates folder: baseline/, web-app/, web-app-hosts/, claude-block.md
#   BASELINE_DIR       the baseline folder (default: $TEMPLATES_DIR/baseline)
#   FAMILIES_DOC       docs/families.md
#   SETTINGS_TEMPLATE  templates/settings.json
#   FLOW_BIN           the folder with flow-project-check and flow-project-fact
#   PIN_CHECK          .github/scripts/check-action-pins.sh
#
# The version-form check needs git, jq, and npm. npm runs offline, with a
# scratch HOME and cache, and with --no-git-tag-version.
#
# Usage: bash tests/templates/test-family-w.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# SC2016: the control mutations are single-quoted on purpose. eval expands
# them inside the control. SC2034: eval reads WA and WH. SC2155: a local that
# holds a command result needs no exit status.
# shellcheck disable=SC2016,SC2034,SC2155

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$REAL_REPO/plugins/flow/templates}"
BASELINE_DIR="${BASELINE_DIR:-$TEMPLATES_DIR/baseline}"
FAMILIES_DOC="${FAMILIES_DOC:-$REAL_REPO/docs/families.md}"
SETTINGS_TEMPLATE="${SETTINGS_TEMPLATE:-$REAL_REPO/templates/settings.json}"
FLOW_BIN="${FLOW_BIN:-$REAL_REPO/plugins/flow/bin}"
PIN_CHECK="${PIN_CHECK:-$REAL_REPO/.github/scripts/check-action-pins.sh}"
CLAUDE_BLOCK="$TEMPLATES_DIR/claude-block.md"
WEB_APP="$TEMPLATES_DIR/web-app"
WEB_HOSTS="$TEMPLATES_DIR/web-app-hosts"

TMPROOT="$(mktemp -d)" || exit 1

# Names that must not appear in a template: they are project facts. The
# match is case-sensitive.
DENY_LIST="MyGunLog ElanRegistry Registry TeamCroc BurgessMachineWorks BurgessGunWorks devkit-sandbox"

# A fake 40-hex commit SHA for the devkit pin rewrite.
FAKE_SHA="0123456789abcdef0123456789abcdef01234567"

# --- Ruby helper -------------------------------------------------------
# y2j.rb <out-dir> <file>...: one Ruby start parses every file. For each file
# that parses, it writes the JSON to <out-dir>/<path with / as _>. A file that
# does not parse gets no output file. Ruby (YAML 1.1) reads the key `on` as
# true, so the helper renames a true key to "on".
cat > "$TMPROOT/y2j.rb" <<'RUBY'
require "yaml"
require "json"
def fix(o)
  case o
  when Hash then o.each_with_object({}) { |(k, v), h| h[k == true ? "on" : k.to_s] = fix(v) }
  when Array then o.map { |v| fix(v) }
  else o
  end
end
out = ARGV.shift
ARGV.each do |f|
  begin
    File.write(File.join(out, f.tr("/", "_")), JSON.generate(fix(YAML.safe_load(File.read(f), aliases: false))))
  rescue StandardError, Psych::SyntaxError
    next
  end
end
RUBY

if command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null \
    && command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    pass "ruby with yaml and json, jq, and git are available"
else
    fail "ruby with yaml and json, jq, and git are available" "install ruby, jq, and git"
    harness_report
fi

# y2j <file>: JSON on stdout, nonzero on a parse error. The file must be in
# the cache that the next two lines fill.
YJ="$TMPROOT/yj"; mkdir -p "$YJ"
# shellcheck disable=SC2046 # the file names hold no space
ruby "$TMPROOT/y2j.rb" "$YJ" $(find "$WEB_APP" "$BASELINE_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort -u) 2>/dev/null
y2j() { local c="$YJ/$(printf '%s' "$1" | tr / _)"; [ -f "$c" ] && cat "$c"; }

# files_in <dir>: each file below <dir>, as a relative path, sorted.
files_in() {
    (cd "$1" 2>/dev/null && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)
}

# strip_gha <file>: the file with each ${{ ... }} GitHub expression removed.
strip_gha() { sed -E 's/\$\{\{[^}]*\}\}//g' "$1"; }

# scratch_git <dir>: a new git repo with a scratch HOME, so that no user or
# system git config (for example commit signing) changes the result.
scratch_git() {
    rm -rf "$1"; mkdir -p "$1/home"
    (cd "$1" && HOME="$1/home" GIT_CONFIG_NOSYSTEM=1 git init -q . 2>/dev/null)
}

# jq filter: true when every key and every array entry of $t is in $f.
SUPERSET='def sup($t; $f):
    if ($t | type) == "object" then
        ($f | type) == "object"
        and all($t | keys[]; . as $k | sup($t[$k]; $f[$k]))
    elif ($t | type) == "array" then
        ($f | type) == "array"
        and all($t[]; . as $e | any($f[]; . == $e))
    else $t == $f end;
sup($t; $f)'

# --- the checks --------------------------------------------------------
# check_whitespace <label> <dir> <files>: no trailing whitespace, no tab in
# YAML, not empty, one final newline.
check_whitespace() {
    local label="$1" dir="$2" files="$3" f rel got=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel=""
        grep -qE '[[:space:]]+$' "$dir/$f" && rel="$rel trailing-whitespace"
        case "$f" in
            *.yml|*.yaml) grep -q "$(printf '\t')" "$dir/$f" && rel="$rel tab" ;;
        esac
        if [ ! -s "$dir/$f" ]; then
            rel="$rel empty"
        elif [ -n "$(tail -c1 "$dir/$f")" ]; then
            rel="$rel no-final-newline"
        elif [ "$(tail -c2 "$dir/$f" | od -An -tx1 | tr -d ' \n')" = "0a0a" ]; then
            rel="$rel extra-final-newline"
        fi
        [ -z "$rel" ] || got="$got [$f:$rel]"
    done <<EOF
$files
EOF
    if [ -z "$got" ] && [ -n "$files" ]; then
        pass "$label: clean whitespace"
    else
        fail "$label: clean whitespace" "problems:${got:- (no files)}"
    fi
}

# version_cells <row label>: the milestone_setup and release_checks cells of
# one row of the version-forms table, one cell on each line. Each cell must
# be in backticks. "\|" in a cell is a "|". Prints nothing on a bad row.
version_cells() {
    awk -v want="$1" '
        /<!-- version-forms:/ { p = 1; next }
        p && /^## / { exit }
        p && /^\|/ {
            line = $0
            gsub(/\\\|/, "\001", line)
            n = split(line, c, "|")
            for (i = 2; i <= 4; i++) { gsub(/^[ ]+|[ ]+$/, "", c[i]) }
            if (c[2] != want) next
            if (n != 5 || c[3] !~ /^`.*`$/ || c[4] !~ /^`.*`$/) exit
            for (i = 3; i <= 4; i++) {
                v = substr(c[i], 2, length(c[i]) - 2)
                gsub(/\001/, "|", v)
                print v
            }
            exit
        }' "$FAMILIES_DOC" 2>/dev/null
}

# check_version_form <name> <row label>: runs the commands of one row in a
# scratch git repo on milestone/v1.2.3. release_checks must pass after
# milestone_setup, and fail on milestone/v1.2.4 with no new setup.
check_version_form() {
    local name="$1" label="$2" cells setup checks repo rc out
    cells="$(version_cells "$label")"
    setup="$(printf '%s\n' "$cells" | sed -n 1p)"
    checks="$(printf '%s\n' "$cells" | sed -n 2p)"
    if [ -n "$setup" ] && [ -n "$checks" ]; then
        pass "version form $name: the table row has milestone_setup and release_checks"
    else
        fail "version form $name: the table row has milestone_setup and release_checks" \
            "row \"| $label |\" missing or not in the form | label | \`cmd\` | \`cmd\` |"
        return
    fi
    if [ "$name" = npm ] && ! command -v npm >/dev/null 2>&1; then
        fail "version form npm: npm is installed" "install npm to run the npm version form"
        return
    fi

    repo="$TMPROOT/version-$name"
    scratch_git "$repo"
    # vrun <command>: runs one command in the repo, offline, with the scratch
    # HOME and npm cache. Output on stdout.
    vrun() {
        (cd "$repo" && HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 \
            npm_config_cache="$repo/home/npm-cache" npm_config_offline=true \
            npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false \
            sh -c "$1" 2>&1)
    }
    vrun 'git checkout -q -b milestone/v1.2.3 && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init' >/dev/null
    [ "$name" = npm ] && printf '{"name":"x","version":"0.0.0"}\n' > "$repo/package.json"

    out="$(vrun "$setup")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        out="$(vrun "$checks")"; rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "version form $name: release_checks passes after milestone_setup"
    else
        fail "version form $name: release_checks passes after milestone_setup" "exit: $rc" "$out"
    fi

    out="$(vrun "$setup")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "version form $name: milestone_setup runs again on the same branch"
    else
        fail "version form $name: milestone_setup runs again on the same branch" "exit: $rc" "$out"
    fi

    vrun 'git checkout -q -b milestone/v1.2.4' >/dev/null
    out="$(vrun "$checks")"; rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "version form $name: release_checks fails on a new milestone branch"
    else
        fail "version form $name: release_checks fails on a new milestone branch" "exit: $rc (want 1)" "$out"
    fi
}

check_family_w() {
    local want got f rel rc files host_files base_files pcj cij base_pcj repo cmd
    files="$(files_in "$WEB_APP")"
    host_files="$(files_in "$WEB_HOSTS")"
    base_files="$(files_in "$BASELINE_DIR")"

    # 1. exact file sets
    want=".claude/hooks/block-env.sh
.claude/project.md
.claude/rules/app-review.md
.claude/settings.json
.github/workflows/ci.yml
.gitignore
.pre-commit-config.yaml
CLAUDE.md"
    if [ "$files" = "$want" ]; then
        pass "web-app: file set is exact"
    else
        fail "web-app: file set is exact" "got: $(printf '%s' "$files" | tr '\n' ' ')"
    fi
    want="a2-tag.md
cloudflare-pages.md"
    if [ "$host_files" = "$want" ]; then
        pass "web-app-hosts: file set is exact"
    else
        fail "web-app-hosts: file set is exact" "got: $(printf '%s' "$host_files" | tr '\n' ' ')"
    fi

    # 2. only .pre-commit-config.yaml overrides a baseline path
    got=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ -e "$WEB_APP/$rel" ] && [ "$rel" != .pre-commit-config.yaml ]; then
            got="$got $rel"
        fi
    done <<EOF
$base_files
EOF
    if [ -z "$got" ] && [ -n "$base_files" ]; then
        pass "web-app: only .pre-commit-config.yaml overrides a baseline path"
    else
        fail "web-app: only .pre-commit-config.yaml overrides a baseline path" "not allowed:${got:- (baseline folder empty)}"
    fi

    # 4a. each YAML file parses
    pcj="{}"; cij="{}"
    while IFS= read -r rel; do
        case "$rel" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac
        if f="$(y2j "$WEB_APP/$rel")"; then
            pass "web-app: parses: $rel"
            case "$rel" in
                .pre-commit-config.yaml) pcj="$f" ;;
                .github/workflows/ci.yml) cij="$f" ;;
            esac
        else
            fail "web-app: parses: $rel"
        fi
    done <<EOF
$files
EOF

    # 3. pre-commit override
    base_pcj="$(y2j "$BASELINE_DIR/.pre-commit-config.yaml")"
    if [ -z "$base_pcj" ]; then
        got="baseline .pre-commit-config.yaml is missing or does not parse"
    else
        got="$(printf '%s' "$base_pcj" | jq -r --argjson f "$pcj" '
        . as $b
        | [ (if ($b | del(.repos)) == ($f | del(.repos)) then empty else "top-level keys" end),
            ($b.repos[] | . as $e
                | select(any(($f.repos // [])[]; . == $e) | not)
                | "repo " + .repo) ] | join(", ")' 2>&1)"
        got="$got$(grep -vxFf "$WEB_APP/.pre-commit-config.yaml" "$BASELINE_DIR/.pre-commit-config.yaml" 2>/dev/null | sed 's/^/ line missing: /' | tr '\n' ' ')"
    fi
    if [ -z "$got" ]; then
        pass "web-app: pre-commit override holds the baseline content"
    else
        fail "web-app: pre-commit override holds the baseline content" "$got"
    fi
    got="$(printf '%s' "$pcj" | jq -r '
        [.repos[]? | select(.repo == "local") | .hooks[]?] as $h
        | [ ["typecheck", "{{typecheck}}"], ["test-quick", "{{test_quick}}"] ][]
        | . as [$id, $entry]
        | select(([$h[] | select(.id == $id and .entry == "bash" and .args == ["-c", $entry]
                    and .language == "system" and .pass_filenames == false)] | length) != 1)
        | $id' 2>&1 | tr '\n' ' ')"
    if [ -z "$got" ]; then
        pass "web-app: pre-commit has the local typecheck and test-quick hooks"
    else
        fail "web-app: pre-commit has the local typecheck and test-quick hooks" "missing or wrong: $got"
    fi

    # 4b. YAML placeholders are full quoted values
    got=""
    while IFS= read -r rel; do
        case "$rel" in
            *.yml|*.yaml) ;;
            *) continue ;;
        esac
        f="$(strip_gha "$WEB_APP/$rel" | grep -F '{{' \
            | grep -vE '^[[:space:]]*(-[[:space:]]+)?([A-Za-z0-9_-]+:[[:space:]]+)?"\{\{[a-z_]+\}\}"[[:space:]]*$')"
        [ -z "$f" ] || got="$got [$rel: $(printf '%s' "$f" | tr '\n' '|')]"
    done <<EOF
$files
EOF
    if [ -z "$got" ]; then
        pass "web-app: each YAML placeholder is a full quoted value"
    else
        fail "web-app: each YAML placeholder is a full quoted value" "bad:$got"
    fi

    # 5. ci.yml
    got="$(printf '%s' "$cij" | jq -c '(.on // {}) | if type == "object" and has("pull_request") then .pull_request else "absent" end')"
    if [ "$got" = null ] || [ "$got" = '{}' ]; then
        pass "web-app: ci.yml runs on each pull_request, with no filter"
    else
        fail "web-app: ci.yml runs on each pull_request, with no filter" "pull_request: $got"
    fi
    got="$(printf '%s' "$cij" | jq -c '.on.push.branches')"
    if [ "$got" = '["main","milestone/**"]' ]; then
        pass "web-app: ci.yml push branches are main and milestone/**"
    else
        fail "web-app: ci.yml push branches are main and milestone/**" "got: $got"
    fi
    got="$(printf '%s' "$cij" | jq -c '.permissions')"
    if [ "$got" = '{"contents":"read"}' ]; then
        pass "web-app: ci.yml permissions are contents: read"
    else
        fail "web-app: ci.yml permissions are contents: read" "got: $got"
    fi
    got="$(printf '%s' "$cij" | jq -r '.jobs.app.name // "(none)"')"
    if [ "$got" = App ]; then
        pass "web-app: ci.yml has the job app with the name App"
    else
        fail "web-app: ci.yml has the job app with the name App" "name: $got"
    fi
    got="$(printf '%s' "$cij" | jq -r '[.jobs.app.steps[]?.run // empty] as $r
        | [("{{lint}}", "{{test}}") | select(. as $c | $r | index($c) | not)] | join(" ")')"
    if [ -z "$got" ]; then
        pass "web-app: ci.yml App job runs {{lint}} and {{test}}"
    else
        fail "web-app: ci.yml App job runs {{lint}} and {{test}}" "no step runs: $got"
    fi
    got="$(printf '%s' "$cij" | jq -r '[.jobs.app.steps[]? | select(has("if")) | (.name // .uses // .run)] | join(", ")')"
    if [ -z "$got" ]; then
        pass "web-app: no step of the App job has an if"
    else
        fail "web-app: no step of the App job has an if" "steps with if: $got"
    fi
    if [ -f "$PIN_CHECK" ] && [ -d "$WEB_APP/.github/workflows" ]; then
        got="$(bash "$PIN_CHECK" "$WEB_APP/.github/workflows" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ]; then
            pass "web-app: check-action-pins.sh passes on the workflows"
        else
            fail "web-app: check-action-pins.sh passes on the workflows" "exit: $rc" "$got"
        fi
    else
        fail "web-app: check-action-pins.sh passes on the workflows" "script or folder missing"
    fi

    # 6. devkit pin rule
    got="$(grep -rhE '^[[:space:]-]*uses:[[:space:]]*unibrain1/devkit/' "$BASELINE_DIR" "$WEB_APP" 2>/dev/null)"
    rel="$(printf '%s' "$got" | grep -c .)"
    f="$(printf '%s\n' "$got" | grep . | grep -vE '@main$')"
    if [ "$rel" -gt 0 ] && [ -z "$f" ]; then
        pass "pin rule: each devkit uses line in baseline and web-app ends in @main"
    else
        fail "pin rule: each devkit uses line in baseline and web-app ends in @main" \
            "devkit uses lines: $rel" "not @main: $(printf '%s' "$f" | tr '\n' '|')"
    fi
    repo="$TMPROOT/pin"
    rm -rf "$repo"; mkdir -p "$repo"
    cp -R "$BASELINE_DIR" "$repo/baseline"; cp -R "$WEB_APP" "$repo/web-app"
    got=""
    find "$repo" -type f \( -name '*.yml' -o -name '*.yaml' \) > "$TMPROOT/pin-files"
    while IFS= read -r f; do
        sed -E "s|^([[:space:]-]*uses:[[:space:]]*unibrain1/devkit/[^@[:space:]]+)@main\$|\\1@$FAKE_SHA # v9.9.9|" \
            "$f" > "$f.new" && mv "$f.new" "$f"
    done < "$TMPROOT/pin-files"
    for rel in baseline web-app; do
        [ -d "$repo/$rel/.github/workflows" ] || continue
        f="$(bash "$PIN_CHECK" "$repo/$rel/.github/workflows" 2>&1)" || got="$got [$rel: $f]"
    done
    f="$(grep -rhE '^[[:space:]-]*uses:[[:space:]]*unibrain1/devkit/.*@main' "$repo" 2>/dev/null)"
    [ -z "$f" ] || got="$got [@main left: $f]"
    if [ -z "$got" ]; then
        pass "pin rule: the Devkit pin rewrite passes check-action-pins.sh and leaves no @main"
    else
        fail "pin rule: the Devkit pin rewrite passes check-action-pins.sh and leaves no @main" "$got"
    fi

    # 7. project.md
    repo="$TMPROOT/pc"
    scratch_git "$repo"
    mkdir -p "$repo/.claude"
    cp "$WEB_APP/.claude/project.md" "$repo/.claude/project.md" 2>/dev/null
    got="$(cd "$repo" && "$FLOW_BIN/flow-project-check" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "web-app: flow-project-check passes on project.md"
    else
        fail "web-app: flow-project-check passes on project.md" "exit: $rc" "$got"
    fi
    got=""
    for rel in test test_quick lint verify plans release_notes deploy milestone_setup release_checks; do
        f="$(cd "$repo" && "$FLOW_BIN/flow-project-fact" "$rel" 2>/dev/null)" && [ -n "$f" ] || got="$got $rel"
    done
    if [ -z "$got" ]; then
        pass "web-app: project.md has each needed key"
    else
        fail "web-app: project.md has each needed key" "missing:$got"
    fi
    f="$(cd "$repo" && "$FLOW_BIN/flow-project-fact" lint 2>/dev/null)"
    if [ "$f" = '{{typecheck}} && {{lint}}' ]; then
        pass "web-app: project.md lint is {{typecheck}} && {{lint}}"
    else
        fail "web-app: project.md lint is {{typecheck}} && {{lint}}" "lint: $f"
    fi

    # 8. version forms
    check_version_form npm npm
    check_version_form version-file "VERSION file"

    # 9. settings.json
    if jq empty "$WEB_APP/.claude/settings.json" >/dev/null 2>&1; then
        pass "web-app: parses: .claude/settings.json"
    else
        fail "web-app: parses: .claude/settings.json"
    fi
    got="$(jq -n --argjson t "$(jq -c . "$SETTINGS_TEMPLATE" 2>/dev/null || echo null)" \
        --argjson f "$(jq -c . "$WEB_APP/.claude/settings.json" 2>/dev/null || echo null)" "$SUPERSET")"
    if [ "$got" = "true" ]; then
        pass "web-app: settings.json is a superset of templates/settings.json"
    else
        fail "web-app: settings.json is a superset of templates/settings.json"
    fi
    want='bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/block-env.sh || { echo "BLOCK: block-env.sh blocked the call, or it did not run." >&2; exit 2; }'
    got="$(jq -r --arg want "$want" '[.hooks.PreToolUse[]? | select(.matcher == "Read|Edit|MultiEdit|Write|NotebookEdit|Grep")
        | .hooks[]? | select(.type == "command" and .command == $want)] | length' \
        "$WEB_APP/.claude/settings.json" 2>/dev/null)"
    if [ "$got" = 1 ]; then
        pass "web-app: settings.json runs block-env.sh on Read|Edit|MultiEdit|Write|NotebookEdit|Grep"
    else
        fail "web-app: settings.json runs block-env.sh on Read|Edit|MultiEdit|Write|NotebookEdit|Grep" "matching hooks: ${got:-none}"
    fi
    # Run the settings command as Claude Code does (sh -c). It must block an
    # .env read with the project root set, and block when the hook cannot run.
    cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$WEB_APP/.claude/settings.json" 2>/dev/null)"
    got=""
    printf '{"tool_input":{"file_path":".env"}}' | CLAUDE_PROJECT_DIR="$WEB_APP" sh -c "$cmd" >/dev/null 2>&1
    rc=$?; [ "$rc" -eq 2 ] || got="$got [project root set: exit $rc]"
    printf '{"tool_input":{"file_path":"README.md"}}' | CLAUDE_PROJECT_DIR="$WEB_APP" sh -c "$cmd" >/dev/null 2>&1
    rc=$?; [ "$rc" -eq 0 ] || got="$got [allowed path: exit $rc]"
    printf '{"tool_input":{"file_path":".env"}}' | env -u CLAUDE_PROJECT_DIR sh -c "$cmd" >/dev/null 2>&1
    rc=$?; [ "$rc" -eq 2 ] || got="$got [project root unset: exit $rc]"
    printf '{"tool_input":{"file_path":".env"}}' | CLAUDE_PROJECT_DIR="$TMPROOT/no-such-dir" sh -c "$cmd" >/dev/null 2>&1
    rc=$?; [ "$rc" -eq 2 ] || got="$got [hook file missing: exit $rc]"
    if [ -n "$cmd" ] && [ -z "$got" ]; then
        pass "web-app: the settings hook command blocks, also when the hook cannot run"
    else
        fail "web-app: the settings hook command blocks, also when the hook cannot run" "got:${got:- (no command)}"
    fi

    # 10. CLAUDE.md and the host files
    got="$(awk '/^<!-- flow:begin/{p=1} p{print} /^<!-- flow:end -->$/{p=0}' "$WEB_APP/CLAUDE.md" 2>/dev/null)"
    if [ -n "$got" ] && [ "$got" = "$(cat "$CLAUDE_BLOCK" 2>/dev/null)" ] \
        && [ "$(grep -c '^<!-- flow:begin' "$WEB_APP/CLAUDE.md")" = "1" ]; then
        pass "web-app: CLAUDE.md flow block equals claude-block.md"
    else
        fail "web-app: CLAUDE.md flow block equals claude-block.md"
    fi
    if grep -qF '{{deployment}}' "$WEB_APP/CLAUDE.md" 2>/dev/null; then
        pass "web-app: CLAUDE.md has {{deployment}}"
    else
        fail "web-app: CLAUDE.md has {{deployment}}"
    fi
    for rel in a2-tag.md cloudflare-pages.md; do
        if [ -s "$WEB_HOSTS/$rel" ] && grep -q '[^[:space:]]' "$WEB_HOSTS/$rel" \
            && ! grep -qF '{{' "$WEB_HOSTS/$rel"; then
            pass "web-app-hosts: $rel has text and no placeholder"
        else
            fail "web-app-hosts: $rel has text and no placeholder"
        fi
    done
    if grep -qF 'Cloudflare Pages' "$WEB_HOSTS/cloudflare-pages.md" 2>/dev/null \
        && grep -qF '`main`' "$WEB_HOSTS/cloudflare-pages.md"; then
        pass "web-app-hosts: cloudflare-pages.md names Cloudflare Pages and main"
    else
        fail "web-app-hosts: cloudflare-pages.md names Cloudflare Pages and main"
    fi
    got=""
    grep -qF 'A2' "$WEB_HOSTS/a2-tag.md" 2>/dev/null || got="$got [A2]"
    grep -qE '^git push [^ ]+ vX\.Y\.Z$' "$WEB_HOSTS/a2-tag.md" 2>/dev/null || got="$got [tag push]"
    grep -qE '^git push .*:refs/heads/main'"'"'?$' "$WEB_HOSTS/a2-tag.md" 2>/dev/null || got="$got [push to :refs/heads/main]"
    if [ -z "$got" ]; then
        pass "web-app-hosts: a2-tag.md names A2, the tag push, and the push to main"
    else
        fail "web-app-hosts: a2-tag.md names A2, the tag push, and the push to main" "missing:$got"
    fi

    # 11. placeholders, project facts, .gitignore, whitespace
    got=""
    while IFS= read -r f; do
        [ -f "$WEB_APP/$f" ] || continue
        for rel in $(strip_gha "$WEB_APP/$f" | grep -oE '\{\{[a-z_]+\}\}' | sort -u); do
            grep -qF -- "\`$rel\`" "$FAMILIES_DOC" 2>/dev/null || got="$got $rel($f)"
        done
    done <<EOF
$files
EOF
    if [ -z "$got" ] && [ -f "$FAMILIES_DOC" ]; then
        pass "web-app: each placeholder is listed in docs/families.md"
    else
        fail "web-app: each placeholder is listed in docs/families.md" "not listed:${got:- (families.md missing)}"
    fi
    got=""
    for rel in $DENY_LIST; do
        f="$(grep -rlF -e "$rel" "$WEB_APP" "$WEB_HOSTS" 2>/dev/null | tr '\n' ' ')"
        [ -z "$f" ] || got="$got [$rel: $f]"
    done
    if [ -z "$got" ]; then
        pass "web-app and web-app-hosts: no project name in a template file"
    else
        fail "web-app and web-app-hosts: no project name in a template file" "found:$got"
    fi
    # git check-ignore tests the effect of the rules, so a reorder or a later
    # "!" rule that commits a secret fails too. The empty core.excludesFile
    # and the scratch XDG_CONFIG_HOME keep the user's global ignore file out.
    got=""
    repo="$TMPROOT/gitignore-$$"
    scratch_git "$repo"
    if [ -f "$WEB_APP/.gitignore" ] && cp "$WEB_APP/.gitignore" "$repo/.gitignore"; then
        for rel in .env .env.local app/.env.production .dev.vars .dev.vars.staging docs/plans/issue-1.md; do
            (cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 git -c core.excludesFile= check-ignore -q -- "$rel") \
                || got="$got [not ignored: $rel]"
        done
        for rel in .env.example config/.env.sample .dev.vars.example src/app.ts; do
            (cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home" GIT_CONFIG_NOSYSTEM=1 git -c core.excludesFile= check-ignore -q -- "$rel") \
                && got="$got [ignored: $rel]"
        done
    else
        got=" [.gitignore missing]"
    fi
    rm -rf "$repo"
    if [ -z "$got" ]; then
        pass "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files"
    else
        fail "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" "$got"
    fi
    check_whitespace web-app "$WEB_APP" "$files"
    check_whitespace web-app-hosts "$WEB_HOSTS" "$host_files"

    # 12. the web-app manual steps name CodeQL default setup and Semgrep
    got="$(awk '/^For `web-app`:$/{p=1; next} p && (/^For / || /^## /){exit} p{print}' "$FAMILIES_DOC" 2>/dev/null | tr '\n' ' ')"
    rel=""
    for f in 'CodeQL default setup' 'Semgrep'; do
        printf '%s' "$got" | grep -qF -- "$f" || rel="$rel [$f]"
    done
    if [ -n "$got" ] && [ -z "$rel" ]; then
        pass "docs/families.md: the web-app manual steps name CodeQL default setup and Semgrep"
    else
        fail "docs/families.md: the web-app manual steps name CodeQL default setup and Semgrep" \
            "missing:${rel:- (no \"For \`web-app\`:\" section)}"
    fi
}

check_family_w

# --- break-it controls -------------------------------------------------
# sub <file> <sed -E expression>: edit one file in place, portably.
sub() {
    sed -E -e "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}
# fresh_copy <scratch-dir>: copy the inputs, and set T, D, S, P, WA, WH.
fresh_copy() {
    SCR="$1"
    rm -rf "$SCR"; mkdir -p "$SCR"
    cp -R "$TEMPLATES_DIR" "$SCR/templates"
    cp "$FAMILIES_DOC" "$SCR/families.md"
    cp "$SETTINGS_TEMPLATE" "$SCR/settings.json"
    cp "$PIN_CHECK" "$SCR/check-action-pins.sh"
    T="$SCR/templates"; D="$SCR/families.md"; S="$SCR/settings.json"; P="$SCR/check-action-pins.sh"
    WA="$T/web-app"; WH="$T/web-app-hosts"
}
# run_on_copy: run this script on the copy. Output on stdout.
run_on_copy() {
    FAMILY_W_NO_CONTROLS=1 TEMPLATES_DIR="$T" BASELINE_DIR="$T/baseline" FAMILIES_DOC="$D" \
        SETTINGS_TEMPLATE="$S" FLOW_BIN="$FLOW_BIN" PIN_CHECK="$P" bash "$SELF" 2>&1
}
# The controls run in parallel. Each one writes its result to $RES/<n>.
RES="$TMPROOT/res"; mkdir -p "$RES"
NCTL=0
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
[ "$JOBS" -gt 8 ] && JOBS=8
[ "$JOBS" -lt 2 ] && JOBS=2
# control <name> <expected-failing-check> <mutation>
# <mutation> runs with T, D, S, P, WA, WH set (all in a scratch copy). The
# script runs on the copy and must print "FAIL: <expected-failing-check>"
# and exit 1.
control() {
    local name="$1" expect="$2" mutation="$3" n
    NCTL=$((NCTL + 1)); n=$NCTL
    printf '%s\n%s\n' "$name" "$expect" > "$RES/$n.name"
    (
        local out rc
        fresh_copy "$TMPROOT/scratch-$n"
        eval "$mutation"
        out="$(run_on_copy)"; rc=$?
        if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL: $expect"; then
            echo ok > "$RES/$n"
        else
            { echo "exit: $rc"; printf '%s\n' "$out" | grep -E '^(FAIL|[0-9]+ scenario)' | head -4; } > "$RES/$n"
        fi
        rm -rf "$TMPROOT/scratch-$n"
    ) &
    if [ $((n % JOBS)) -eq 0 ]; then wait; fi
}
# controls_report: wait for all controls, then print one result for each.
controls_report() {
    local i name expect
    wait
    i=1
    while [ "$i" -le "$NCTL" ]; do
        name="$(sed -n 1p "$RES/$i.name")"; expect="$(sed -n 2p "$RES/$i.name")"
        if [ "$(cat "$RES/$i" 2>/dev/null)" = ok ]; then
            pass "control $name: check failed as expected ($expect)"
        else
            fail "control $name: check did not fail as expected" "expected: FAIL: $expect" \
                "$(tr '\n' ' ' < "$RES/$i" 2>/dev/null)"
        fi
        i=$((i + 1))
    done
}

if [ "${FAMILY_W_NO_CONTROLS:-}" != "1" ]; then
    # The unbroken copy must pass, or every control proves nothing.
    fresh_copy "$TMPROOT/scratch-clean"
    out="$(run_on_copy)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "control clean-copy: the unbroken scratch copy passes"
    else
        fail "control clean-copy: the unbroken scratch copy passes" "exit: $rc" "$(printf '%s\n' "$out" | grep '^FAIL' | head -5)"
    fi

    # 1. file sets
    control file-extra "web-app: file set is exact" 'touch "$WA/.env.example"'
    control file-missing "web-app: file set is exact" 'rm "$WA/.claude/rules/app-review.md"'
    control host-extra "web-app-hosts: file set is exact" 'printf "x\n" > "$WH/vercel.md"'
    # 2. baseline overrides
    control override-workflow "web-app: only .pre-commit-config.yaml overrides a baseline path" \
        'cp "$T/baseline/.github/workflows/claude.yml" "$WA/.github/workflows/claude.yml"'
    control override-dependabot "web-app: only .pre-commit-config.yaml overrides a baseline path" \
        'cp "$T/baseline/.github/dependabot.yml" "$WA/.github/dependabot.yml"'
    # 3. pre-commit override
    control baseline-precommit-rev "web-app: pre-commit override holds the baseline content" \
        'sub "$T/baseline/.pre-commit-config.yaml" "s/rev: v8\.30\.1/rev: v8.30.2/"'
    control baseline-precommit-comment "web-app: pre-commit override holds the baseline content" \
        'sub "$T/baseline/.pre-commit-config.yaml" "s/gitleaks scans only/gitleaks reads only/"'
    control baseline-precommit-missing "web-app: pre-commit override holds the baseline content" \
        'rm "$T/baseline/.pre-commit-config.yaml"'
    control override-drops-hook "web-app: pre-commit override holds the baseline content" \
        'sub "$WA/.pre-commit-config.yaml" "/^      - id: check-json$/d"'
    control local-typecheck-entry "web-app: pre-commit has the local typecheck and test-quick hooks" \
        'sub "$WA/.pre-commit-config.yaml" "s/- \"\{\{typecheck\}\}\"/- \"{{lint}}\"/"'
    control local-no-shell "web-app: pre-commit has the local typecheck and test-quick hooks" \
        'sub "$WA/.pre-commit-config.yaml" "/^          - \"-c\"$/d"'
    control local-test-quick-pass-filenames "web-app: pre-commit has the local typecheck and test-quick hooks" \
        'sub "$WA/.pre-commit-config.yaml" "\$ s/pass_filenames: false/pass_filenames: true/"'
    control local-language "web-app: pre-commit has the local typecheck and test-quick hooks" \
        'sub "$WA/.pre-commit-config.yaml" "/id: typecheck/,/pass_filenames/ s/language: system/language: script/"'
    control local-commented-out "web-app: pre-commit has the local typecheck and test-quick hooks" \
        'sub "$WA/.pre-commit-config.yaml" "/^  - repo: local$/,\$ s/^/# /"'
    # 4. YAML parse and placeholder form
    control yaml-broken "web-app: parses: .github/workflows/ci.yml" \
        'printf "a: [1, 2\nb: : :\n" > "$WA/.github/workflows/ci.yml"'
    control yaml-placeholder-unquoted "web-app: each YAML placeholder is a full quoted value" \
        'sub "$WA/.github/workflows/ci.yml" "s/run: \"\{\{test\}\}\"/run: {{test}}/"'
    control yaml-placeholder-in-string "web-app: each YAML placeholder is a full quoted value" \
        'sub "$WA/.github/workflows/ci.yml" "s/run: \"\{\{lint\}\}\"/run: \"npm run {{lint}}\"/"'
    control yaml-placeholder-block "web-app: each YAML placeholder is a full quoted value" \
        'sub "$WA/.github/workflows/ci.yml" "s/run: \"\{\{test\}\}\"/run: |\n          {{test}}/"'
    control yaml-placeholder-comment "web-app: each YAML placeholder is a full quoted value" \
        'printf "# The {{lint}} step runs the linter.\n" >> "$WA/.pre-commit-config.yaml"'
    # 5. ci.yml
    control ci-no-pull-request "web-app: ci.yml runs on each pull_request, with no filter" \
        'sub "$WA/.github/workflows/ci.yml" "/^  pull_request:$/d"'
    control ci-pull-request-filter "web-app: ci.yml runs on each pull_request, with no filter" \
        'sub "$WA/.github/workflows/ci.yml" "s/^  pull_request:$/  pull_request: {branches: [main]}/"'
    control ci-push-branches "web-app: ci.yml push branches are main and milestone/**" \
        'sub "$WA/.github/workflows/ci.yml" "s#\"milestone/\*\*\"#\"release/**\"#"'
    control ci-permissions "web-app: ci.yml permissions are contents: read" \
        'sub "$WA/.github/workflows/ci.yml" "s/^  contents: read$/  contents: write/"'
    control ci-job-name "web-app: ci.yml has the job app with the name App" \
        'sub "$WA/.github/workflows/ci.yml" "s/^    name: App$/    name: Build/"'
    control ci-job-id "web-app: ci.yml has the job app with the name App" \
        'sub "$WA/.github/workflows/ci.yml" "s/^  app:$/  build:/"'
    control ci-no-test-step "web-app: ci.yml App job runs {{lint}} and {{test}}" \
        'sub "$WA/.github/workflows/ci.yml" "s/run: \"\{\{test\}\}\"/run: \"{{verify}}\"/"'
    control ci-step-if "web-app: no step of the App job has an if" \
        'sub "$WA/.github/workflows/ci.yml" "s/^      - name: Test$/      - name: Test\n        if: false/"'
    control ci-unpinned-action "web-app: check-action-pins.sh passes on the workflows" \
        'sub "$WA/.github/workflows/ci.yml" "s#actions/checkout@[0-9a-f]+#actions/checkout@v7#"'
    # 6. devkit pin rule
    control pin-not-main "pin rule: each devkit uses line in baseline and web-app ends in @main" \
        'sub "$T/baseline/.github/workflows/claude.yml" "s#claude\.yml@main#claude.yml@v1.4.0#"'
    control pin-none "pin rule: each devkit uses line in baseline and web-app ends in @main" \
        'rm -r "$T/baseline/.github/workflows"'
    control pin-rewrite-other-action "pin rule: the Devkit pin rewrite passes check-action-pins.sh and leaves no @main" \
        'printf "  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@v4\n" >> "$T/baseline/.github/workflows/secrets-scan.yml"'
    # 7. project.md
    control project-md-unknown-key "web-app: flow-project-check passes on project.md" \
        'printf -- "- bogus_key: \`x\`\n" >> "$WA/.claude/project.md"'
    control project-md-no-release-checks "web-app: project.md has each needed key" \
        'sub "$WA/.claude/project.md" "/^- release_checks:/d"'
    control project-md-lint "web-app: project.md lint is {{typecheck}} && {{lint}}" \
        'sub "$WA/.claude/project.md" "s/^- lint: .*/- lint: \`{{lint}}\`/"'
    control project-md-lint-or "web-app: project.md lint is {{typecheck}} && {{lint}}" \
        'sub "$WA/.claude/project.md" "/^- lint:/ s/ && / || /"'
    # 8. version forms
    control version-npm-row-missing "version form npm: the table row has milestone_setup and release_checks" \
        'sub "$D" "s/^\| npm \|/| node |/"'
    control version-npm-always-passes "version form npm: release_checks fails on a new milestone branch" \
        'sub "$D" "/^\| npm \|/ s/exit 1; \}/exit 0; }/"'
    control version-npm-check-field "version form npm: release_checks passes after milestone_setup" \
        'sub "$D" "/^\| npm \|/ s/jq -r \.version/jq -r .name/"'
    control version-npm-setup-wrong "version form npm: release_checks passes after milestone_setup" \
        'sub "$D" "/^\| npm \|/ s/npm version \"/npm version \"x/"'
    control version-npm-not-idempotent "version form npm: milestone_setup runs again on the same branch" \
        'sub "$D" "/^\| npm \|/ s/ --allow-same-version//"'
    control version-file-setup-wrong "version form version-file: release_checks passes after milestone_setup" \
        'sub "$D" "s/> VERSION\`/> VERSION.txt\`/"'
    control version-file-always-passes "version form version-file: release_checks fails on a new milestone branch" \
        'sub "$D" "/^\| VERSION file \|/ s/exit 1; \}/exit 0; }/"'
    # 9. settings.json
    control json-broken "web-app: parses: .claude/settings.json" \
        'printf "{ \"a\": \n" > "$WA/.claude/settings.json"'
    control settings-allow-missing "web-app: settings.json is a superset of templates/settings.json" \
        'sub "$WA/.claude/settings.json" "/flow-repo:/d"'
    control settings-template-grew "web-app: settings.json is a superset of templates/settings.json" \
        'sub "$S" "s/\"Bash\(flow-repo:\*\)\",/\"Bash(flow-repo:*)\", \"Bash(flow-new:*)\",/"'
    control settings-hook-matcher "web-app: settings.json runs block-env.sh on Read|Edit|MultiEdit|Write|NotebookEdit|Grep" \
        'sub "$WA/.claude/settings.json" "s/\"matcher\": \"Read\|Edit\|MultiEdit\|Write\|NotebookEdit\|Grep\"/\"matcher\": \"Read|Edit|Write\"/"'
    control settings-hook-no-grep "web-app: settings.json runs block-env.sh on Read|Edit|MultiEdit|Write|NotebookEdit|Grep" \
        'sub "$WA/.claude/settings.json" "s/\|NotebookEdit\|Grep\"/|NotebookEdit\"/"'
    control settings-hook-command "web-app: settings.json runs block-env.sh on Read|Edit|MultiEdit|Write|NotebookEdit|Grep" \
        'sub "$WA/.claude/settings.json" "s#\"bash #\"#"'
    control settings-hook-no-fallback "web-app: the settings hook command blocks, also when the hook cannot run" \
        'sub "$WA/.claude/settings.json" "s# \\|\\| \\{[^}]*\\}##"'
    control settings-hook-blocks-all "web-app: the settings hook command blocks, also when the hook cannot run" \
        'sub "$WA/.claude/settings.json" "s#block-env.sh \\|\\| #block-env.sh; #"'
    # 10. CLAUDE.md and host files
    control claude-block-edited "web-app: CLAUDE.md flow block equals claude-block.md" \
        'sub "$WA/CLAUDE.md" "s/One PR for each/One PR per/"'
    control claude-block-source "web-app: CLAUDE.md flow block equals claude-block.md" \
        'sub "$T/claude-block.md" "s/hotfix branches/hotfix starts/"'
    control claude-no-deployment "web-app: CLAUDE.md has {{deployment}}" \
        'sub "$WA/CLAUDE.md" "s/\{\{deployment\}\}/TBD/"'
    control host-placeholder "web-app-hosts: a2-tag.md has text and no placeholder" \
        'printf "{{app_name}}\n" >> "$WH/a2-tag.md"'
    control host-empty "web-app-hosts: cloudflare-pages.md has text and no placeholder" \
        ': > "$WH/cloudflare-pages.md"'
    control host-cloudflare-name "web-app-hosts: cloudflare-pages.md names Cloudflare Pages and main" \
        'sub "$WH/cloudflare-pages.md" "s/Cloudflare Pages/Cloudflare/g"'
    control host-cloudflare-main "web-app-hosts: cloudflare-pages.md names Cloudflare Pages and main" \
        'sub "$WH/cloudflare-pages.md" "s/\`main\`/\`production\`/g"'
    control host-a2-no-tag-push "web-app-hosts: a2-tag.md names A2, the tag push, and the push to main" \
        'sub "$WH/a2-tag.md" "/^git push [^ ]+ vX\.Y\.Z$/d"'
    control host-a2-no-main-push "web-app-hosts: a2-tag.md names A2, the tag push, and the push to main" \
        'sub "$WH/a2-tag.md" "/:refs\/heads\/main/d"'
    control host-a2-short-main "web-app-hosts: a2-tag.md names A2, the tag push, and the push to main" \
        'sub "$WH/a2-tag.md" "s#:refs/heads/main#:main#"'
    # 11. placeholders, project facts, .gitignore, whitespace
    control placeholder-unlisted-doc "web-app: each placeholder is listed in docs/families.md" \
        'sub "$D" "s/\{\{verify\}\}/{{full_check}}/"'
    control placeholder-unlisted-dotfile "web-app: each placeholder is listed in docs/families.md" \
        'printf "# {{extra_key}}\n" >> "$WA/.gitignore"'
    control project-fact-name "web-app and web-app-hosts: no project name in a template file" \
        'printf "MyGunLog\n" >> "$WA/CLAUDE.md"'
    control project-fact-host-file "web-app and web-app-hosts: no project name in a template file" \
        'printf "See the Registry repo.\n" >> "$WH/a2-tag.md"'
    control gitignore-env "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/^\.env$/d"'
    control gitignore-example "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/^!\.env\.example$/d"'
    control gitignore-sample "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/^!\.env\.sample$/d"'
    control gitignore-plans "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/docs\/plans/d"'
    control gitignore-dev-vars "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/^\.dev\.vars$/d"'
    control gitignore-dev-vars-star "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/^\.dev\.vars\.\*$/d"'
    control gitignore-dev-vars-example "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'sub "$WA/.gitignore" "/^!\.dev\.vars\.example$/d"'
    control gitignore-negation-first "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'printf "!.env.example\n!.env.sample\n.env\n.env.*\n.dev.vars\ndocs/plans/\n" > "$WA/.gitignore"'
    control gitignore-unignore-env "web-app: .gitignore ignores .env, .dev.vars, their .<name> files, and docs/plans/, not the example files" \
        'printf "!.env\n" >> "$WA/.gitignore"'
    control whitespace-trailing "web-app: clean whitespace" \
        'printf "trailing \n" >> "$WA/.claude/rules/app-review.md"'
    control whitespace-no-newline "web-app-hosts: clean whitespace" \
        'printf "no newline" >> "$WH/cloudflare-pages.md"'
    control whitespace-dotfile "web-app: clean whitespace" \
        'printf "\n" >> "$WA/.gitignore"'
    # 12. CodeQL and Semgrep
    control doc-no-codeql "docs/families.md: the web-app manual steps name CodeQL default setup and Semgrep" \
        'sub "$D" "s/CodeQL default setup/code scanning/"'
    control doc-no-semgrep "docs/families.md: the web-app manual steps name CodeQL default setup and Semgrep" \
        'sub "$D" "s/the Semgrep app/the scanner app/"'
    controls_report
fi

harness_report
