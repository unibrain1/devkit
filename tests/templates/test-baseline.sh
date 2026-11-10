#!/bin/bash
#
# Tests for the baseline files in plugins/flow/templates/baseline/: YAML
# validity, pinned hook revs, caller refs, permissions and triggers equal
# to docs/ci-workflows.md, caller permissions, inputs, and secrets that the
# reusable workflows accept, the merge-gate check name, the Dependabot
# config, the action pin check, whitespace, and the rules in the docs.
#
# Env overrides, for the break-it checks on scratch copies:
#   BASELINE_DIR  the baseline folder
#   CI_DOCS       docs/ci-workflows.md
#   BASELINE_DOC  docs/baseline.md
#   SETUP_MD      plugins/flow/commands/setup.md
#
# Usage: bash tests/templates/test-baseline.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASELINE_DIR="${BASELINE_DIR:-$REAL_REPO/plugins/flow/templates/baseline}"
CI_DOCS="${CI_DOCS:-$REAL_REPO/docs/ci-workflows.md}"
BASELINE_DOC="${BASELINE_DOC:-$REAL_REPO/docs/baseline.md}"
SETUP_MD="${SETUP_MD:-$REAL_REPO/plugins/flow/commands/setup.md}"
PIN_CHECK="$REAL_REPO/.github/scripts/check-action-pins.sh"
REUSABLE_SECRETS="$REAL_REPO/.github/workflows/secrets-scan.yml"

TMPROOT="$(mktemp -d)" || exit 1

PRECOMMIT="$BASELINE_DIR/.pre-commit-config.yaml"
WF="$BASELINE_DIR/.github/workflows"
DEPENDABOT="$BASELINE_DIR/.github/dependabot.yml"
CALLERS="claude-code-review.yml claude.yml secrets-scan.yml"

# --- Ruby helpers ------------------------------------------------------
# y2j.rb <file>: YAML to JSON. Ruby (YAML 1.1) reads the key `on` as true,
# so the helper renames a true key to "on".
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
src = ARGV[0] == "-" ? $stdin.read : File.read(ARGV[0])
puts JSON.generate(fix(YAML.safe_load(src, aliases: false)))
RUBY

# docblock.rb <docs-file> <path-comment>: prints the body of the fenced yaml
# block whose first line is "# <path-comment>". Prints nothing when absent.
cat > "$TMPROOT/docblock.rb" <<'RUBY'
lines = File.readlines(ARGV[0])
want = "# #{ARGV[1]}"
i = 0
while i < lines.size
  if lines[i].chomp == "```yaml" && lines[i + 1].to_s.chomp == want
    j = i + 2
    out = []
    while j < lines.size && lines[j].chomp != "```"
      out << lines[j]
      j += 1
    end
    print out.join
    break
  end
  i += 1
end
RUBY

if command -v ruby >/dev/null 2>&1 && ruby -ryaml -rjson -e 'exit 0' 2>/dev/null; then
    pass "ruby with yaml and json is available"
else
    fail "ruby with yaml and json is available" "install ruby"
    harness_report
fi

# y2j <file>: JSON on stdout, nonzero on a parse error.
y2j() { ruby "$TMPROOT/y2j.rb" "$1" 2>/dev/null; }

# --- A1: file set ------------------------------------------------------
want_files=".github/dependabot.yml
.github/workflows/claude-code-review.yml
.github/workflows/claude.yml
.github/workflows/secrets-scan.yml
.pre-commit-config.yaml"
got_files="$(cd "$BASELINE_DIR" 2>/dev/null && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)"
if [ "$got_files" = "$want_files" ]; then
    pass "baseline has exactly the five files"
else
    fail "baseline has exactly the five files" "got: $(printf '%s' "$got_files" | tr '\n' ' ')"
    harness_report
fi
ALL_FILES="$PRECOMMIT $DEPENDABOT $WF/claude-code-review.yml $WF/claude.yml $WF/secrets-scan.yml"

# --- A3: YAML parses ---------------------------------------------------
printf 'a: [1, 2\nb: : :\n' > "$TMPROOT/broken.yml"
if y2j "$TMPROOT/broken.yml" >/dev/null; then
    fail "control: parse helper rejects broken YAML"
else
    pass "control: parse helper rejects broken YAML"
fi
for f in $ALL_FILES; do
    if y2j "$f" >/dev/null; then
        pass "parses: ${f#"$BASELINE_DIR"/}"
    else
        fail "parses: ${f#"$BASELINE_DIR"/}"
    fi
done
if ! PC_JSON="$(y2j "$PRECOMMIT")"; then
    fail "pre-commit config parses for the hook checks"
    harness_report
fi

# --- A4: rev is a version tag or a 40-hex SHA --------------------------
rev_ok() { printf '%s' "$1" | grep -Eq '^(v?[0-9]+(\.[0-9]+)+|[0-9a-f]{40})$'; }
for bad in main master HEAD latest ""; do
    if rev_ok "$bad"; then
        fail "control: rev '$bad' is rejected"
    else
        pass "control: rev '$bad' is rejected"
    fi
done
revs="$(printf '%s' "$PC_JSON" | jq -r '.repos[] | select(.repo != "local") | .repo + " " + (.rev // "")')"
if [ -z "$revs" ]; then
    fail "pre-commit config has remote repos"
else
    while IFS=' ' read -r repo rev; do
        # A5: each remote repo has a rev
        if [ -z "$rev" ]; then
            fail "rev present: $repo"
        elif rev_ok "$rev"; then
            pass "rev pinned: $repo @ $rev"
        else
            fail "rev pinned: $repo" "rev: $rev"
        fi
    done <<< "$revs"
fi

# --- A6: hook ids ------------------------------------------------------
check_hooks() {
    local repo="$1" ids="$2" id found
    for id in $ids; do
        found="$(printf '%s' "$PC_JSON" | jq -r --arg r "$repo" --arg i "$id" \
            '[.repos[] | select(.repo == $r) | .hooks[] | select(.id == $i)] | length')"
        if [ "$found" = "1" ]; then
            pass "hook $id under $repo"
        else
            fail "hook $id under $repo" "count: $found"
        fi
    done
}
check_hooks https://github.com/pre-commit/pre-commit-hooks \
    "trailing-whitespace end-of-file-fixer check-yaml check-json check-merge-conflict check-added-large-files"
check_hooks https://github.com/DavidAnson/markdownlint-cli2 "markdownlint-cli2"
check_hooks https://github.com/gitleaks/gitleaks "gitleaks"

# --- A7: commented test_quick slot -------------------------------------
comments="$(grep -E '^[[:space:]]*#' "$PRECOMMIT")"
if printf '%s\n' "$comments" | grep -q 'test_quick' \
    && printf '%s\n' "$comments" | grep -q 'pre-push' \
    && printf '%s\n' "$comments" | grep -Eq '^[[:space:]]*#[[:space:]]*-[[:space:]]+repo:[[:space:]]+local'; then
    pass "commented test_quick slot names test_quick, pre-push, and repo: local"
else
    fail "commented test_quick slot names test_quick, pre-push, and repo: local"
fi
local_repos="$(printf '%s' "$PC_JSON" | jq '[.repos[] | select(.repo == "local")] | length')"
if [ "$local_repos" = "0" ]; then
    pass "the parsed config has no local repo"
else
    fail "the parsed config has no local repo" "count: $local_repos"
fi

# perm_gaps <caller-json> <reusable-json>: print each scope that a job of
# the reusable workflow asks for at a higher level than the caller job
# grants. GitHub does not start a caller that grants less.
perm_gaps() {
    jq -nr --argjson c "$1" --argjson r "$2" '
        def rank: if . == "write" then 2 elif . == "read" then 1 else 0 end;
        ([$c.jobs[]][0].permissions // {}) as $have
        | [$r.permissions, ($r.jobs[] | .permissions)]
        | map(select(type == "object") | to_entries[]
              | select((.value | rank) > ($have[.key] // "none" | rank)) | .key)
        | unique | join(",")'
}
if [ -n "$(perm_gaps '{"jobs":{"a":{"permissions":{"contents":"read"}}}}' \
    '{"jobs":{"b":{"permissions":{"contents":"write"}}}}')" ] \
    && [ -z "$(perm_gaps '{"jobs":{"a":{"permissions":{"contents":"write"}}}}' \
    '{"permissions":{"contents":"read"},"jobs":{"b":{}}}')" ]; then
    pass "control: perm_gaps finds read < write and accepts write >= read"
else
    fail "control: perm_gaps finds read < write and accepts write >= read"
fi

# --- A8-A11: callers ---------------------------------------------------
docs_json() { # docs_json <name>: JSON of the docs example, or nothing
    local body
    body="$(ruby "$TMPROOT/docblock.rb" "$CI_DOCS" ".github/workflows/$1")"
    [ -n "$body" ] || return 1
    printf '%s' "$body" | ruby "$TMPROOT/y2j.rb" -
}
for name in $CALLERS; do
    if ! CJ="$(y2j "$WF/$name")"; then
        fail "caller parses: $name"
        continue
    fi
    # A8: uses ref
    # The caller claude-code-review.yml calls the reusable claude-review.yml.
    reusable="$name"
    [ "$name" = "claude-code-review.yml" ] && reusable="claude-review.yml"
    uses="$(printf '%s' "$CJ" | jq -r '[.jobs[].uses] | join(",")')"
    if [ "$uses" = "unibrain1/devkit/.github/workflows/$reusable@main" ]; then
        pass "$name: uses unibrain1/devkit/.github/workflows/$reusable@main"
    else
        fail "$name: uses unibrain1/devkit/.github/workflows/$reusable@main" "uses: $uses"
    fi
    # The caller passes only the inputs and secrets that the reusable
    # workflow declares, and grants each permission that it asks for.
    if ! RJ="$(y2j "$REAL_REPO/.github/workflows/$reusable")"; then
        fail "$name: reusable $reusable parses"
        continue
    fi
    extra="$(jq -nr --argjson c "$CJ" --argjson r "$RJ" '
        [$c.jobs[]][0] as $j
        | (($j.with // {}) | keys - (($r.on.workflow_call.inputs // {}) | keys))
          + (($j.secrets // {}) | keys - (($r.on.workflow_call.secrets // {}) | keys))
        | join(",")')"
    if [ -z "$extra" ]; then
        pass "$name: each with: and secrets: key is declared in $reusable"
    else
        fail "$name: each with: and secrets: key is declared in $reusable" "not declared: $extra"
    fi
    # A caller with no permissions block gives the repo default token, so
    # only a caller with a block can grant too little.
    if [ "$(printf '%s' "$CJ" | jq '[.jobs[]][0] | has("permissions")')" = "true" ]; then
        gaps="$(perm_gaps "$CJ" "$RJ")"
        if [ -z "$gaps" ]; then
            pass "$name: grants each permission that $reusable asks for"
        else
            fail "$name: grants each permission that $reusable asks for" "missing: $gaps"
        fi
    fi
    # The permissions lists must not be empty for the two Claude callers.
    if [ "$name" != "secrets-scan.yml" ]; then
        n="$(printf '%s' "$CJ" | jq '[.jobs[].permissions // {} | keys[]] | length')"
        if [ "${n:-0}" -ge 4 ]; then
            pass "$name: has a permissions block with $n scopes"
        else
            fail "$name: has a permissions block" "scopes: ${n:-none}"
        fi
    fi
    # A9, A10: compare with the docs example
    if ! DJ="$(docs_json "$name")" || [ -z "$DJ" ]; then
        fail "$name: docs example found in ci-workflows.md" "no yaml block with first line '# .github/workflows/$name'"
        continue
    fi
    pass "$name: docs example found in ci-workflows.md"
    # Job-level permissions; the caller and the docs must match, also when both have none.
    cp="$(printf '%s' "$CJ" | jq -cS '[.jobs[] | .permissions // null], (.permissions // null)')"
    dp="$(printf '%s' "$DJ" | jq -cS '[.jobs[] | .permissions // null], (.permissions // null)')"
    if [ "$cp" = "$dp" ] && [ -n "$cp" ]; then
        pass "$name: permissions equal the docs example"
    else
        fail "$name: permissions equal the docs example" "caller: $cp" "docs:   $dp"
    fi
    ct="$(printf '%s' "$CJ" | jq -cS '.on')"
    dt="$(printf '%s' "$DJ" | jq -cS '.on')"
    if [ -n "$ct" ] && [ "$ct" = "$dt" ] && [ "$ct" != "null" ]; then
        pass "$name: triggers equal the docs example"
    else
        fail "$name: triggers equal the docs example" "caller: $ct" "docs:   $dt"
    fi
done

# A11: no with: in the secrets caller; reusable default keeps --only-verified
sj="$(y2j "$WF/secrets-scan.yml")"
# The merge gate needs the check name "secrets-scan / trufflehog": the
# caller job id, then the name of the reusable job.
rj="$(y2j "$REUSABLE_SECRETS")"
cjobs="$(printf '%s' "$sj" | jq -c '.jobs | keys')"
rname="$(printf '%s' "$rj" | jq -r 'if .jobs.trufflehog then (.jobs.trufflehog.name // "trufflehog") else "" end')"
if [ "$cjobs" = '["secrets-scan"]' ] && [ "$rname" = "trufflehog" ]; then
    pass "check name is secrets-scan / trufflehog"
else
    fail "check name is secrets-scan / trufflehog" "caller jobs: $cjobs" "reusable job name: $rname"
fi
withs="$(printf '%s' "$sj" | jq '[.jobs[] | has("with")] | map(select(.)) | length')"
if [ "$withs" = "0" ]; then
    pass "secrets-scan caller has no with:"
else
    fail "secrets-scan caller has no with:"
fi
if grep -Eq 'default:[[:space:]]*"--only-verified"' "$REUSABLE_SECRETS"; then
    pass "reusable secrets-scan.yml default is --only-verified"
else
    fail "reusable secrets-scan.yml default is --only-verified"
fi
if grep -q 'no-verification' "$WF/secrets-scan.yml"; then
    fail "secrets-scan caller does not name --no-verification"
else
    pass "secrets-scan caller does not name --no-verification"
fi

# --- A12: dependabot ---------------------------------------------------
if DB="$(y2j "$DEPENDABOT")"; then
    ok="$(printf '%s' "$DB" | jq -r '
        (.version == 2) and ((.updates | length) == 1)
        and (.updates[0]["package-ecosystem"] == "github-actions")
        and (.updates[0].directory == "/")
        and (.updates[0].schedule.interval == "weekly")
        and (.updates[0]["commit-message"].prefix == "chore(deps)")
        and (.updates[0].ignore == [{"dependency-name": "unibrain1/devkit"}])')"
    if [ "$ok" = "true" ]; then
        pass "dependabot: v2, one github-actions entry, /, weekly, prefix chore(deps), ignores devkit"
    else
        fail "dependabot: v2, one github-actions entry, /, weekly, prefix chore(deps), ignores devkit" "$(printf '%s' "$DB" | jq -c .)"
    fi
else
    fail "dependabot parses"
fi

# --- A13: action pins --------------------------------------------------
if [ -x "$PIN_CHECK" ]; then
    err="$("$PIN_CHECK" "$WF" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "check-action-pins.sh accepts the baseline workflows"
    else
        fail "check-action-pins.sh accepts the baseline workflows" "exit: $rc" "stderr: $err"
    fi
else
    fail "check-action-pins.sh is executable" "$PIN_CHECK"
fi
nuses="$(cat "$WF"/*.yml | grep -Ec '^[[:space:]]*(-[[:space:]]+)?uses:')"
if [ "$nuses" = "3" ]; then
    pass "the workflow folder has three uses: lines"
else
    fail "the workflow folder has three uses: lines" "count: $nuses"
fi

# --- A14: whitespace and final newline ---------------------------------
for f in $ALL_FILES; do
    rel="${f#"$BASELINE_DIR"/}"
    bad=""
    grep -nE '[[:space:]]+$' "$f" >/dev/null && bad="$bad trailing-whitespace"
    grep -q "$(printf '\t')" "$f" && bad="$bad tab"
    [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && bad="$bad no-final-newline"
    [ -s "$f" ] || bad="$bad empty"
    if [ -z "$bad" ]; then
        pass "clean whitespace: $rel"
    else
        fail "clean whitespace: $rel" "problems:$bad"
    fi
done

# --- A15: docs rules ---------------------------------------------------
need() { # need <file> <label> <grep-opts> <pattern>
    if [ ! -f "$1" ]; then
        fail "$2" "file missing: $1"
    elif grep -q"${3:-}" -- "$4" "$1" 2>/dev/null; then
        pass "$2"
    else
        fail "$2" "pattern not found in $1: $4"
    fi
}
for pat in 'required_checks' 'secrets-scan / trufflehog' 'semgrep-cloud-platform/scan' \
    'Semgrep' 'GitGuardian' 'secret scanning' 'push protection' '20 seconds' \
    'pre-push' 'pre-commit install'; do
    need "$BASELINE_DOC" "docs/baseline.md names '$pat'" F "$pat"
done
need "$BASELINE_DOC" "docs/baseline.md names branch protection (any case)" Fi "branch protection"
need "$CI_DOCS" "ci-workflows.md pin rule names outside contributors" F "outside contributors"
# near <file> <anchor> <pattern> <lines> <label>: passes when <pattern>
# is within <lines> lines of a line with <anchor>. Both are fixed strings,
# and the match ignores case.
near() {
    if [ -f "$1" ] && grep -B"$4" -A"$4" -Fi -- "$2" "$1" | grep -qFi -- "$3"; then
        pass "$5"
    else
        fail "$5" "'$3' not within $4 lines of '$2' in $1"
    fi
}
# The pin rule states @main close to the outside-contributors text.
if [ -f "$CI_DOCS" ] && grep -B4 -A4 -F "outside contributors" "$CI_DOCS" | grep -qF "@main"; then
    pass "ci-workflows.md pin rule names @main near outside contributors"
else
    fail "ci-workflows.md pin rule names @main near outside contributors"
fi
# The outside-contributor rule names a release tag and a SHA.
for pat in '@vX.Y.Z' 'SHA'; do
    near "$CI_DOCS" "outside contributors" "$pat" 2 \
        "ci-workflows.md pin rule names '$pat' near outside contributors"
done
# The merge gate rule ties each tool to the right visibility.
near "$BASELINE_DOC" "Private repo" "required_checks" 2 \
    "docs/baseline.md names required_checks near the private repo rule"
near "$BASELINE_DOC" "Public repo" "branch protection" 2 \
    "docs/baseline.md names branch protection near the public repo rule"
near "$BASELINE_DOC" "public repo" "push protection" 2 \
    "docs/baseline.md names push protection near the public repo text"
need "$BASELINE_DOC" "docs/baseline.md names 'Jim adds'" F "Jim adds"
need "$BASELINE_DOC" "docs/baseline.md names 'CLAUDE_CODE_OAUTH_TOKEN'" F "CLAUDE_CODE_OAUTH_TOKEN"
need "$SETUP_MD" "setup.md runs flow-baseline --status" F "flow-baseline --status"
need "$SETUP_MD" "setup.md runs flow-baseline --apply" F "flow-baseline --apply"

harness_report
