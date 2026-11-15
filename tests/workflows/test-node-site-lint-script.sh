#!/bin/bash
#
# Tests the lint_script input and the "Lint site" step of node-site.yml.
#
# Checks:
#   - input: lint_script is declared, type string, optional, default empty
#   - jobs: the job ids stay build, lint, and functions
#   - step: "Lint site" is in the build job after "Install dependencies" and
#     "Build site", with the if: that skips an empty value
#   - env: the value reaches the step through env LINT_SCRIPT only, and no
#     ${{ inputs.lint_script }} text is in the run: block
#   - behavior: the run: block runs with a stub npm. A good name runs
#     "npm run <name>". A bad name exits 1 with the error, and npm is not called.
#     The error does not print the value. A name that starts with - . or :, and
#     a name with a newline, are bad names.
#   - doc: docs/ci-workflows.md has a lint_script row in the node-site inputs
#
# Break-it controls: each check also runs against a broken scratch copy of the
# workflow or the doc, and it must fail there, with the reason of that check.
# Each mutation removes the old copy first, and a mutation that does not apply
# fails its control.
#
# NODE_SITE_YML and CI_DOC point the test at other copies of the two files.
#
# Usage: bash tests/workflows/test-node-site-lint-script.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The single quotes hold literal ${{ }}, backticks, and $( ) on purpose.
# shellcheck disable=SC2016

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NODE_SITE_YML="${NODE_SITE_YML:-$REAL_REPO/.github/workflows/node-site.yml}"
CI_DOC="${CI_DOC:-$REAL_REPO/docs/ci-workflows.md}"

TMPROOT="$(mktemp -d)"
mkdir -p "$TMPROOT/bin"

if [ ! -f "$NODE_SITE_YML" ] || [ ! -f "$CI_DOC" ]; then
    fail "input files exist" "workflow: $NODE_SITE_YML" "doc: $CI_DOC"
    harness_report
fi

# Ruby (YAML 1.1) reads the key `on` as true, so the helper maps it back.
# It prints the facts the checks need as JSON.
cat > "$TMPROOT/facts.rb" <<'RUBY'
require "yaml"
require "json"
doc = YAML.safe_load(File.read(ARGV[0]))
on = doc["on"] || doc[true] || {}
inputs = (on["workflow_call"] || {})["inputs"] || {}
jobs = doc["jobs"] || {}
steps = ((jobs["build"] || {})["steps"]) || []
names = steps.map { |s| s["name"] }
step = steps.find { |s| s["name"] == "Lint site" }
puts JSON.generate(
  "input" => inputs["lint_script"],
  "has_input" => inputs.key?("lint_script"),
  "job_ids" => jobs.keys,
  "step_names" => names,
  "step_count" => names.count("Lint site"),
  "step" => step
)
RUBY

# facts <yml>: JSON on stdout. Empty output and nonzero on a parse error.
facts() { ruby "$TMPROOT/facts.rb" "$1" 2>/dev/null; }

# Each check_* function takes a workflow (or doc) path, prints the reason on
# stdout, and returns 1 when the check fails.

check_input() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    [ "$(echo "$f" | jq -r '.has_input')" = "true" ] || { echo "input lint_script is not declared"; return 1; }
    [ "$(echo "$f" | jq -r '.input.type')" = "string" ] || { echo "type is not string"; return 1; }
    [ "$(echo "$f" | jq -r '.input.required')" = "false" ] || { echo "required is not false"; return 1; }
    [ "$(echo "$f" | jq -r '.input | has("default")')" = "true" ] || { echo "no default"; return 1; }
    [ "$(echo "$f" | jq -r '.input.default | @json')" = '""' ] || { echo "default is not the empty string"; return 1; }
    return 0
}

check_job_ids() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    [ "$(echo "$f" | jq -c '.job_ids')" = '["build","lint","functions"]' ] \
        || { echo "job ids are $(echo "$f" | jq -c '.job_ids')"; return 1; }
    return 0
}

check_step_position() {
    local f idx_i idx_b idx_l
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    [ "$(echo "$f" | jq -r '.step_count')" = "1" ] || { echo "build job needs exactly one Lint site step"; return 1; }
    idx_i="$(echo "$f" | jq -r '.step_names | index("Install dependencies")')"
    idx_b="$(echo "$f" | jq -r '.step_names | index("Build site")')"
    idx_l="$(echo "$f" | jq -r '.step_names | index("Lint site")')"
    if [ "$idx_i" = "null" ] || [ "$idx_b" = "null" ] || [ "$idx_l" = "null" ]; then
        echo "a needed step is missing"; return 1
    fi
    [ "$idx_l" -gt "$idx_i" ] || { echo "Lint site is not after Install dependencies"; return 1; }
    [ "$idx_l" -gt "$idx_b" ] || { echo "Lint site is not after Build site"; return 1; }
    return 0
}

check_step_if() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    [ "$(echo "$f" | jq -r '.step.if')" = "inputs.lint_script != ''" ] \
        || { echo "if: is $(echo "$f" | jq -r '.step.if')"; return 1; }
    return 0
}

check_step_env() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    [ "$(echo "$f" | jq -r '.step.env.LINT_SCRIPT')" = '${{ inputs.lint_script }}' ] \
        || { echo "env LINT_SCRIPT is not set from inputs.lint_script"; return 1; }
    [ "$(echo "$f" | jq -r '.step.env | length')" = "1" ] \
        || { echo "env has more than LINT_SCRIPT"; return 1; }
    # The run: text must not hold any expression.
    if echo "$f" | jq -r '.step.run // ""' | grep -q '\${{'; then
        echo "run: holds a \${{ }} expression"; return 1
    fi
    return 0
}

# check_behavior <yml>: runs the extracted run: block with a stub npm.
check_behavior() {
    local f script bindir calls out rc name
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    script="$TMPROOT/step.sh"
    echo "$f" | jq -r '.step.run // ""' > "$script"
    [ -s "$script" ] || { echo "no run: text"; return 1; }
    bindir="$TMPROOT/stubbin"
    calls="$TMPROOT/npm-calls"
    mkdir -p "$bindir"
    cat > "$bindir/npm" <<STUB
#!/bin/bash
echo "\$*" >> "$calls"
exit 0
STUB
    chmod +x "$bindir/npm"

    for name in lint lint:md lint_site.v2-x; do
        rm -f "$calls"
        out="$(cd "$TMPROOT" && PATH="$bindir:$PATH" LINT_SCRIPT="$name" bash -e "$script" 2>&1)"; rc=$?
        [ "$rc" -eq 0 ] || { echo "good name '$name' exit $rc: $out"; return 1; }
        [ -f "$calls" ] || { echo "good name '$name': npm not called"; return 1; }
        [ "$(cat "$calls")" = "run $name" ] \
            || { echo "good name '$name': npm got '$(cat "$calls")'"; return 1; }
    done

    # The error must not print the value: a newline in it can start a workflow
    # command. The last six names use only allowed characters but start with
    # a dash, a dot, or a colon, or hold a newline.
    for name in 'x;rm -rf /' '$(id)' 'a b' '`id`' 'a|b' '-x&y' \
        --version -- -s --silent .x :x $'lint\nid'; do
        rm -f "$calls"
        out="$(cd "$TMPROOT" && PATH="$bindir:$PATH" LINT_SCRIPT="$name" bash -e "$script" 2>&1)"; rc=$?
        [ "$rc" -ne 0 ] || { echo "bad name '$name' exit 0"; return 1; }
        case "$out" in
            *"$name"*) echo "bad name '$name': error prints the value: $out"; return 1 ;;
        esac
        case "$out" in
            *"::error::lint_script is not a valid npm script name. Use letters, digits, and : _ . - only. Do not start with : . or -."*) ;;
            *) echo "bad name '$name': error text missing: $out"; return 1 ;;
        esac
        [ ! -f "$calls" ] || { echo "bad name '$name': npm was called"; return 1; }
    done
    return 0
}

# check_doc <md>: a lint_script row is in the node-site inputs table.
check_doc() {
    local row
    row="$(grep -E '^\| `lint_script` \| string \| `""` \|' "$1")"
    [ -n "$row" ] || { echo "no lint_script row in the inputs table"; return 1; }
    return 0
}

# run_real <label> <function> <file>
run_real() {
    local out
    if out="$("$2" "$3")"; then pass "$1"; else fail "$1" "$out"; fi
}

run_real "input: lint_script is string, optional, default empty" check_input "$NODE_SITE_YML"
run_real "jobs: ids stay build, lint, functions" check_job_ids "$NODE_SITE_YML"
run_real "step: Lint site is after Install dependencies and Build site" check_step_position "$NODE_SITE_YML"
run_real "step: if: skips an empty lint_script" check_step_if "$NODE_SITE_YML"
run_real "env: value comes through env only, no expression in run:" check_step_env "$NODE_SITE_YML"
run_real "behavior: good names run npm run <name>, bad names exit 1" check_behavior "$NODE_SITE_YML"
run_real "doc: ci-workflows.md has a lint_script row" check_doc "$CI_DOC"

# control <label> <function> <file> <reason>: the check must fail on the broken
# copy, and the reason text must name the check that this control targets.
control() {
    local out
    if out="$("$2" "$3")"; then
        fail "control $1: check passed on the broken copy"
        return
    fi
    case "$out" in
        *"$4"*) pass "control $1: check failed as expected ($out)" ;;
        *) fail "control $1: check failed for another reason" "wanted: $4" "got: $out" ;;
    esac
}

BROKEN="$TMPROOT/broken.yml"

# mutate_sed <label> <function> <reason> <sed-arg> ...: builds the copy, then
# runs the control. A stale copy is removed first. A sed error or a no-op
# edit fails the control.
mutate_sed() {
    local label="$1" fn="$2" reason="$3"
    shift 3
    rm -f "$BROKEN"
    if ! sed "$@" "$NODE_SITE_YML" > "$BROKEN"; then
        fail "control $label: sed failed"
        return
    fi
    if cmp -s "$BROKEN" "$NODE_SITE_YML"; then
        fail "control $label: the edit changed nothing"
        return
    fi
    control "$label" "$fn" "$BROKEN" "$reason"
}

# mutate_ruby <label> <function> <reason> <ruby-code>: the code reads ARGV[0]
# and writes ARGV[1]. It must call abort when its edit does not apply.
mutate_ruby() {
    local label="$1" fn="$2" reason="$3" err
    rm -f "$BROKEN"
    if ! err="$(ruby -e "$4" "$NODE_SITE_YML" "$BROKEN" 2>&1)"; then
        fail "control $label: the mutation did not apply" "$err"
        return
    fi
    if [ ! -s "$BROKEN" ] || cmp -s "$BROKEN" "$NODE_SITE_YML"; then
        fail "control $label: the edit changed nothing"
        return
    fi
    control "$label" "$fn" "$BROKEN" "$reason"
}

mutate_sed "remove the input" check_input "input lint_script is not declared" \
    -e '/^      lint_script:$/,/^        default: ""$/d'
mutate_sed "default is not empty" check_input "default is not the empty string" \
    -e '/^      lint_script:$/,/^      markdown_globs:$/s/default: ""/default: "lint"/'
mutate_sed "input is required" check_input "required is not false" \
    -e '/^      lint_script:$/,/^      markdown_globs:$/s/required: false/required: true/'
mutate_sed "rename build job" check_job_ids "job ids are" \
    -e 's/^  build:$/  compile:/'
mutate_sed "drop the if:" check_step_if "if: is" \
    -e "/^        if: inputs.lint_script != ''\$/d"
mutate_sed "if: tests another input" check_step_if "if: is" \
    -e "s/^        if: inputs.lint_script != ''\$/        if: inputs.build_script != ''/"
mutate_ruby "drop the env" check_step_env "env LINT_SCRIPT is not set" '
  t = File.read(ARGV[0])
  t2 = t.sub("        env:\n          LINT_SCRIPT: ${{ inputs.lint_script }}\n        run: |\n          if ! [[", "        run: |\n          if ! [[")
  abort "pattern not found" if t2 == t
  File.write(ARGV[1], t2)
'
mutate_sed "expression in run:" check_step_env "run: holds a" \
    -e 's/^          npm run "\$LINT_SCRIPT"$/          npm run ${{ inputs.lint_script }}/'
mutate_sed "drop the name check" check_behavior "exit 0" \
    -e '/^          if ! \[\[ "\$LINT_SCRIPT"/,/^          fi$/d'
mutate_sed "loose name check" check_behavior "exit 0" \
    -e 's/\^\[A-Za-z0-9_\]\[A-Za-z0-9:_\.-\]\*\$/^.+$/'
mutate_sed "old name check allows a leading dash" check_behavior "bad name '--version' exit 0" \
    -e 's/\^\[A-Za-z0-9_\]\[A-Za-z0-9:_\.-\]\*\$/^[A-Za-z0-9:_.-]+$/'
mutate_sed "drop the error text" check_behavior "error text missing" \
    -e 's/lint_script is not a valid npm script name/bad name/'
mutate_sed "error prints the value" check_behavior "error prints the value" \
    -e 's/::error::lint_script is not a valid npm script name\./&: $LINT_SCRIPT/'
mutate_sed "wrong npm script" check_behavior "npm got" \
    -e 's/^          npm run "\$LINT_SCRIPT"$/          npm run lint/'
mutate_sed "rename the step" check_step_position "needs exactly one Lint site step" \
    -e 's/- name: Lint site$/- name: Lint the site/'

# Move the Lint site step before Install dependencies.
mutate_ruby "step before Install dependencies" check_step_position "Lint site is not after Install dependencies" '
  t = File.read(ARGV[0])
  m = t.match(/^      # The name reaches.*?^          npm run "\$LINT_SCRIPT"\n/m) or abort "no block"
  t2 = t.sub(m[0], "")
  t2 = t2.sub("      - name: Install dependencies\n", m[0] + "\n      - name: Install dependencies\n")
  abort "Install dependencies step not found" if t2 == t
  File.write(ARGV[1], t2)
'

# Doc controls.
BROKEN_DOC="$TMPROOT/broken.md"
rm -f "$BROKEN_DOC"
grep -v '^| `lint_script`' "$CI_DOC" > "$BROKEN_DOC"
if [ $? -gt 1 ] || cmp -s "$BROKEN_DOC" "$CI_DOC"; then
    fail "control drop the doc row: the edit changed nothing"
else
    control "drop the doc row" check_doc "$BROKEN_DOC" "no lint_script row"
fi
rm -f "$BROKEN_DOC"
if ! sed 's/^| `lint_script` | string | `""` |/| `lint_script` | string | `lint` |/' "$CI_DOC" > "$BROKEN_DOC" \
    || cmp -s "$BROKEN_DOC" "$CI_DOC"; then
    fail "control wrong doc default: the edit changed nothing"
else
    control "wrong doc default" check_doc "$BROKEN_DOC" "no lint_script row"
fi

harness_report
