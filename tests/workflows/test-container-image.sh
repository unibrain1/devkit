#!/bin/bash
#
# Tests container-image.yml and its section in docs/ci-workflows.md.
#
# Checks:
#   - tags step: the build job has one "Tags" step with id tags and run: text
#   - expr: the Tags run: text holds no ${{ }} expression
#   - events: the real Tags run: block runs for each event case with
#     GITHUB_OUTPUT set to a scratch file. A pull request gives push=false and
#     no tags. A push to main gives exactly edge and sha-<7>. A vX.Y.Z tag
#     gives exactly X.Y.Z, X.Y, and latest. The image name is lowercase, and
#     an image input wins over the repo name.
#   - rejects: each other event, ref, SHA, or image exits 1 with an error,
#     and the step writes nothing to GITHUB_OUTPUT
#   - structure: workflow_call, inputs and defaults, jobs hadolint and build,
#     build needs hadolint, packages: write on build only, and the login and
#     build-push steps read the Tags outputs. The hadolint step and the
#     build-push file: read the dockerfile input. The build job sets up
#     QEMU and Buildx before build-push. Only a run that pushes writes the
#     cache.
#   - pins: at least 5 uses: lines, each pinned to a 40-hex SHA with a
#     version comment
#   - doc: the container-image.yml section of docs/ci-workflows.md has the
#     tag table rows, the host pull-tag rule, the Monitoring example, and a
#     caller example with the strict tag filter and one concurrency group
#     for all tag runs
#
# Break-it controls: each check also runs against a broken scratch copy of
# the workflow or the doc, and it must fail there, with the reason of that
# check. A mutation that does not apply fails its control.
#
# CONTAINER_IMAGE_YML and CI_DOC point the test at other copies of the files.
#
# Usage: bash tests/workflows/test-container-image.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

# The single quotes hold literal ${{ }} and $ text on purpose.
# shellcheck disable=SC2016

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_IMAGE_YML="${CONTAINER_IMAGE_YML:-$REAL_REPO/.github/workflows/container-image.yml}"
CI_DOC="${CI_DOC:-$REAL_REPO/docs/ci-workflows.md}"

TMPROOT="$(mktemp -d)"

if [ ! -f "$CONTAINER_IMAGE_YML" ] || [ ! -f "$CI_DOC" ]; then
    fail "input files exist" "workflow: $CONTAINER_IMAGE_YML" "doc: $CI_DOC"
    harness_report
fi

# Ruby (YAML 1.1) reads the key `on` as true, so the helper maps it back.
# It prints the facts the checks need as JSON.
cat > "$TMPROOT/facts.rb" <<'RUBY'
require "yaml"
require "json"
doc = YAML.safe_load(File.read(ARGV[0]))
on = doc["on"] || doc[true] || {}
jobs = doc["jobs"] || {}
build = jobs["build"] || {}
steps = build["steps"] || []
tags = steps.select { |s| s["name"] == "Tags" }
uses = ->(name) { steps.find { |s| s["uses"].to_s.start_with?(name + "@") } || {} }
lint_steps = (jobs["hadolint"] || {})["steps"] || []
puts JSON.generate(
  "on_keys" => on.is_a?(Hash) ? on.keys : [],
  "inputs" => (on["workflow_call"] || {})["inputs"] || {},
  "top_permissions" => doc["permissions"],
  "job_ids" => jobs.keys,
  "build_needs" => build["needs"],
  "build_permissions" => build["permissions"],
  "hadolint_permissions" => (jobs["hadolint"] || {})["permissions"],
  "tags_count" => tags.length,
  "tags_step" => tags.first || {},
  "login" => uses.call("docker/login-action"),
  "push_step" => uses.call("docker/build-push-action"),
  "build_actions" => steps.map { |s| s["uses"].to_s.split("@").first.to_s },
  "lint_step" => lint_steps.find { |s| s["uses"].to_s.start_with?("hadolint/hadolint-action@") } || {}
)
RUBY

# facts <yml>: JSON on stdout. Empty output and nonzero on a parse error.
facts() { ruby "$TMPROOT/facts.rb" "$1" 2>/dev/null; }

# Each check_* function takes a workflow (or doc) path, prints the reason on
# stdout, and returns 1 when the check fails.

check_tags_step() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    [ "$(echo "$f" | jq -r '.tags_count')" = "1" ] || { echo "build job needs exactly one Tags step"; return 1; }
    [ "$(echo "$f" | jq -r '.tags_step.id')" = "tags" ] || { echo "Tags step id is not tags"; return 1; }
    [ -n "$(echo "$f" | jq -r '.tags_step.run // "" | gsub("\\s"; "")')" ] \
        || { echo "Tags step has an empty run: block"; return 1; }
    return 0
}

check_no_expr() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    if echo "$f" | jq -r '.tags_step.run // ""' | grep -q '\${{'; then
        echo "Tags run: holds a \${{ }} expression"; return 1
    fi
    return 0
}

# run_case <script> <event> <ref> <sha> <image> <repository>: runs the
# block. Sets RC, OUT (stdout and stderr), PUSH, TAGS (sorted), and RAW
# (the whole GITHUB_OUTPUT file).
run_case() {
    local script="$1" gho="$TMPROOT/github_output"
    rm -f "$gho"
    : > "$gho"
    OUT="$(cd "$TMPROOT" && GITHUB_OUTPUT="$gho" EVENT="$2" REF="$3" SHA="$4" \
        IMAGE="$5" REPOSITORY="$6" bash -e "$script" 2>&1)"
    RC=$?
    RAW="$(cat "$gho")"
    PUSH="$(grep '^push=' "$gho" | sed 's/^push=//')"
    TAGS="$(awk '/^tags<<TAGS_EOF$/ {on=1; next} /^TAGS_EOF$/ {on=0} on' "$gho" | LC_ALL=C sort)"
}

SHA1="0123456789abcdef0123456789abcdef01234567"
SHA2="fedcba9876543210fedcba9876543210fedcba98"

# expect_ok <label> <event> <ref> <sha> <image> <repository> <push> <tags>
# <tags> is one tag on each line, in any order.
expect_ok() {
    local want
    run_case "$SCRIPT" "$2" "$3" "$4" "$5" "$6"
    [ "$RC" -eq 0 ] || { echo "case $1: exit $RC: $OUT"; return 1; }
    printf '%s\n' "$RAW" | grep -q '^push=' || { echo "case $1: no push key"; return 1; }
    printf '%s\n' "$RAW" | grep -q '^tags<<TAGS_EOF$' || { echo "case $1: no tags key"; return 1; }
    [ "$PUSH" = "$7" ] || { echo "case $1: push=$PUSH, wanted $7"; return 1; }
    want="$(printf '%s' "$8" | LC_ALL=C sort)"
    [ "$TAGS" = "$want" ] || { echo "case $1: tags are [$(echo "$TAGS" | tr '\n' ' ')], wanted [$(echo "$want" | tr '\n' ' ')]"; return 1; }
    return 0
}

# expect_reject <label> <event> <ref> <sha> <image> <repository>
expect_reject() {
    run_case "$SCRIPT" "$2" "$3" "$4" "$5" "$6"
    [ "$RC" -eq 1 ] || { echo "reject case $1: exit $RC, wanted 1"; return 1; }
    [ -z "$RAW" ] || { echo "reject case $1: GITHUB_OUTPUT is not empty"; return 1; }
    case "$OUT" in
        *"::error::"*) ;;
        *) echo "reject case $1: no ::error:: line"; return 1 ;;
    esac
    return 0
}

write_script() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    SCRIPT="$TMPROOT/tags.sh"
    echo "$f" | jq -r '.tags_step.run // ""' > "$SCRIPT"
    [ -n "$(tr -d '[:space:]' < "$SCRIPT")" ] || { echo "no Tags run: text"; return 1; }
    return 0
}

check_events() {
    local repo=unibrain1/monitoring img=ghcr.io/unibrain1/monitoring
    write_script "$1" || return 1
    expect_ok "pull request" pull_request refs/pull/7/merge "$SHA1" "" "$repo" false "" || return 1
    expect_ok "main" push refs/heads/main "$SHA1" "" "$repo" true \
        "$img:edge
$img:sha-0123456" || return 1
    expect_ok "v1.2.3" push refs/tags/v1.2.3 "$SHA2" "" "$repo" true \
        "$img:1.2.3
$img:1.2
$img:latest" || return 1
    expect_ok "v10.0.0" push refs/tags/v10.0.0 "$SHA2" "" "$repo" true \
        "$img:10.0.0
$img:10.0
$img:latest" || return 1
    expect_ok "uppercase owner" push refs/heads/main "$SHA1" "" Unibrain1/Monitoring true \
        "$img:edge
$img:sha-0123456" || return 1
    expect_ok "image input" push refs/heads/main "$SHA1" ghcr.io/Unibrain1/Other "$repo" true \
        "ghcr.io/unibrain1/other:edge
ghcr.io/unibrain1/other:sha-0123456" || return 1
    return 0
}

check_rejects() {
    local repo=unibrain1/monitoring ref
    write_script "$1" || return 1
    for ref in refs/tags/v1.2.3-rc.1 refs/tags/v1.2.3rc1 refs/tags/v1.2.3.4 \
        refs/tags/v1.2 refs/tags/v1 refs/tags/v01.2.3 refs/tags/v1.02.3 \
        refs/tags/v1.2.03 refs/tags/1.2.3 refs/tags/foo refs/tags/latest \
        refs/heads/develop refs/heads/v1.2.3 refs/heads/main2 refs/heads/main/x \
        refs/pull/7/merge "" $'refs/heads/main\nx' $'refs/tags/v1.2.3\n' \
        $'refs/tags/v1.2.3\r'; do
        expect_reject "push $ref" push "$ref" "$SHA1" "" "$repo" || return 1
    done
    expect_reject "workflow_dispatch" workflow_dispatch refs/heads/main "$SHA1" "" "$repo" || return 1
    expect_reject "release" release refs/tags/v1.2.3 "$SHA1" "" "$repo" || return 1
    expect_reject "empty event" "" refs/heads/main "$SHA1" "" "$repo" || return 1
    expect_reject "empty SHA on main" push refs/heads/main "" "" "$repo" || return 1
    expect_reject "empty SHA on tag" push refs/tags/v1.2.3 "" "" "$repo" || return 1
    expect_reject "short SHA" push refs/heads/main 0123456 "" "$repo" || return 1
    expect_reject "image with a tag" push refs/heads/main "$SHA1" ghcr.io/a/b:1 "$repo" || return 1
    expect_reject "image with a newline" push refs/heads/main "$SHA1" $'ghcr.io/a/b\nx' "$repo" || return 1
    expect_reject "image with a space" pull_request refs/pull/7/merge "$SHA1" "ghcr.io/a b" "$repo" || return 1
    return 0
}

check_structure() {
    local f
    f="$(facts "$1")" || { echo "YAML does not parse"; return 1; }
    echo "$f" | jq -e '.on_keys == ["workflow_call"]' > /dev/null \
        || { echo "trigger is not workflow_call only"; return 1; }
    [ "$(echo "$f" | jq -c '.inputs | keys')" = '["context","dockerfile","image","platforms"]' ] \
        || { echo "inputs are $(echo "$f" | jq -c '.inputs | keys')"; return 1; }
    [ "$(echo "$f" | jq -c '[.inputs[] | .default]')" = '["",".","Dockerfile","linux/amd64,linux/arm64"]' ] \
        || { echo "input defaults are $(echo "$f" | jq -c '[.inputs[] | .default]')"; return 1; }
    [ "$(echo "$f" | jq -c '.job_ids')" = '["hadolint","build"]' ] \
        || { echo "job ids are $(echo "$f" | jq -c '.job_ids')"; return 1; }
    [ "$(echo "$f" | jq -r '.build_needs')" = "hadolint" ] || { echo "build does not need hadolint"; return 1; }
    [ "$(echo "$f" | jq -c '.top_permissions')" = '{"contents":"read"}' ] \
        || { echo "top permissions are $(echo "$f" | jq -c '.top_permissions')"; return 1; }
    [ "$(echo "$f" | jq -c '.build_permissions')" = '{"contents":"read","packages":"write"}' ] \
        || { echo "build permissions are $(echo "$f" | jq -c '.build_permissions')"; return 1; }
    [ "$(echo "$f" | jq -c '.hadolint_permissions')" = 'null' ] \
        || { echo "hadolint job has its own permissions"; return 1; }
    [ "$(echo "$f" | jq -r '.login.if')" = "steps.tags.outputs.push == 'true'" ] \
        || { echo "login if: is $(echo "$f" | jq -r '.login.if')"; return 1; }
    [ "$(echo "$f" | jq -r '.push_step.with.push')" = "\${{ steps.tags.outputs.push == 'true' }}" ] \
        || { echo "build-push push: does not read the Tags output"; return 1; }
    [ "$(echo "$f" | jq -r '.push_step.with.tags')" = '${{ steps.tags.outputs.tags }}' ] \
        || { echo "build-push tags: does not read the Tags output"; return 1; }
    [ "$(echo "$f" | jq -r '.push_step.with.platforms')" = '${{ inputs.platforms }}' ] \
        || { echo "build-push platforms: does not read the input"; return 1; }
    [ "$(echo "$f" | jq -r '.push_step.with.file')" = '${{ inputs.dockerfile }}' ] \
        || { echo "build-push file: does not read the input"; return 1; }
    [ "$(echo "$f" | jq -r '.push_step.with.context')" = '${{ inputs.context }}' ] \
        || { echo "build-push context: does not read the input"; return 1; }
    [ "$(echo "$f" | jq -r '.lint_step.with.dockerfile')" = '${{ inputs.dockerfile }}' ] \
        || { echo "hadolint dockerfile: does not read the input"; return 1; }
    echo "$f" | jq -e '.build_actions
        | (index("docker/setup-qemu-action")) as $q
        | (index("docker/setup-buildx-action")) as $b
        | (index("docker/build-push-action")) as $p
        | $q != null and $b != null and $p != null and $q < $p and $b < $p' > /dev/null \
        || { echo "build job does not set up QEMU and Buildx before build-push"; return 1; }
    [ "$(echo "$f" | jq -r '.push_step.with."cache-to"')" = "\${{ steps.tags.outputs.push == 'true' && 'type=gha,mode=max' || '' }}" ] \
        || { echo "build-push cache-to: does not depend on the Tags push output"; return 1; }
    return 0
}

check_pins() {
    local lines n bad
    lines="$(grep -E '^[[:space:]-]*uses:' "$1")"
    n="$(printf '%s\n' "$lines" | grep -c 'uses:')"
    [ "$n" -ge 5 ] || { echo "only $n uses: lines"; return 1; }
    bad="$(printf '%s\n' "$lines" | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$')"
    [ -z "$bad" ] || { echo "not pinned with a version comment: $(echo "$bad" | sed 's/^ *//' | head -1)"; return 1; }
    return 0
}

# doc_section <md>: the container-image.yml section, up to the next ## heading.
doc_section() {
    awk '/^## `container-image\.yml`$/ {on=1; print; next} on && /^## / {on=0} on' "$1"
}

check_doc() {
    local sec row
    sec="$(doc_section "$1")"
    [ -n "$sec" ] || { echo "no container-image.yml section"; return 1; }
    for row in \
        '| `pull_request` | No | None |' \
        '| `push` to `main` | Yes | `edge`, `sha-<first 7 of the SHA>` |' \
        '| `push` of tag `vX.Y.Z` | Yes | `X.Y.Z`, `X.Y`, `latest` |' \
        '| Other event or ref | No | None. The job fails. |'; do
        printf '%s\n' "$sec" | grep -qxF "$row" || { echo "tag table row missing: $row"; return 1; }
    done
    printf '%s\n' "$sec" | grep -qF 'The host must pull `latest` or a version tag' \
        || { echo "host pull-tag rule missing"; return 1; }
    printf '%s\n' "$sec" | grep -qF 'Monitoring changes its host pull tag from `:main` to `:latest`.' \
        || { echo "Monitoring example missing"; return 1; }
    printf '%s\n' "$sec" | grep -qxF '    tags: ["v[0-9]+.[0-9]+.[0-9]+"]' \
        || { echo "caller example tag filter is not strict"; return 1; }
    printf '%s\n' "$sec" | grep -qxF "  group: \${{ github.workflow }}-\${{ startsWith(github.ref, 'refs/tags/') && 'release' || github.ref }}" \
        || { echo "caller example concurrency group is not shared by tag runs"; return 1; }
    return 0
}

# run_real <label> <function> <file>
run_real() {
    local out
    if out="$("$2" "$3")"; then pass "$1"; else fail "$1" "$out"; fi
}

run_real "tags step: one Tags step with id tags and run: text" check_tags_step "$CONTAINER_IMAGE_YML"
run_real "expr: no expression in the Tags run: text" check_no_expr "$CONTAINER_IMAGE_YML"
run_real "events: PR, main, and vX.Y.Z give the exact push flag and tags" check_events "$CONTAINER_IMAGE_YML"
run_real "rejects: each other event, ref, SHA, or image exits 1 with no output" check_rejects "$CONTAINER_IMAGE_YML"
run_real "structure: trigger, inputs, jobs, permissions, Tags outputs" check_structure "$CONTAINER_IMAGE_YML"
run_real "pins: each uses: is a 40-hex SHA with a version comment" check_pins "$CONTAINER_IMAGE_YML"
run_real "doc: tag table, host pull-tag rule, Monitoring example, caller example" check_doc "$CI_DOC"

# control <label> <function> <file> <reason>: the check must fail on the
# broken copy, and the reason text must name the check that this control
# targets.
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

# mutate <label> <function> <reason> <file> <old> <new>: replaces the first
# <old> text with <new> in a copy of <file>, then runs the control. A stale
# copy is removed first. Text that is not found fails the control.
mutate() {
    local label="$1" fn="$2" reason="$3" src="$4" broken err
    broken="$TMPROOT/broken.${src##*.}"
    rm -f "$broken"
    if ! err="$(ruby -e '
        t = File.read(ARGV[0])
        i = t.index(ARGV[2]) or abort "text not found"
        t[i, ARGV[2].length] = ARGV[3]
        File.write(ARGV[1], t)
    ' "$src" "$broken" "$5" "$6" 2>&1)"; then
        fail "control $label: the mutation did not apply" "$err"
        return
    fi
    control "$label" "$fn" "$broken" "$reason"
}

Y="$CONTAINER_IMAGE_YML"
mutate "rename the Tags step" check_tags_step "exactly one Tags step" "$Y" \
    '- name: Tags' '- name: Image tags'
mutate "empty Tags block" check_tags_step "empty run: block" "$Y" \
    '        run: |
          set -euo pipefail' '        run: " "
        x-old: |
          set -euo pipefail'
mutate "main emits latest" check_events "case main: tags are" "$Y" \
    'tags="$image:edge"$'"'"'\n'"'"'"$image:sha-${SHA:0:7}"' \
    'tags="$image:edge"$'"'"'\n'"'"'"$image:sha-${SHA:0:7}"$'"'"'\n'"'"'"$image:latest"'
mutate "X.Y dropped" check_events "case v1.2.3: tags are" "$Y" \
    '"$image:$major.$minor"$'"'"'\n'"'"'' ''
mutate "PR emits push=true" check_events "case pull request: push=true" "$Y" \
    'push=false' 'push=true'
mutate "no lowercase" check_events "case uppercase owner" "$Y" \
    "tr '[:upper:]' '[:lower:]'" 'cat'
mutate "image input ignored" check_events "case image input" "$Y" \
    'image="${IMAGE:-ghcr.io/$REPOSITORY}"' 'image="ghcr.io/$REPOSITORY"'
mutate "rc tag allowed" check_rejects "reject case push refs/tags/v1.2.3-rc.1" "$Y" \
    '$num\.$num\.$num$ ]]' '$num\.$num\.$num ]]'
mutate "leading zero allowed" check_rejects "reject case push refs/tags/v01.2.3" "$Y" \
    "num='(0|[1-9][0-9]*)'" "num='([0-9]+)'"
mutate "workflow_dispatch allowed" check_rejects "reject case workflow_dispatch" "$Y" \
    'elif [ "$EVENT" != "push" ]; then' 'elif false; then'
mutate "empty SHA allowed" check_rejects "reject case empty SHA on main" "$Y" \
    'elif ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then' 'elif false; then'
mutate "expression in run:" check_no_expr "run: holds a" "$Y" \
    'elif [ "$REF" = "refs/heads/main" ]; then' 'elif [ "${{ github.ref }}" = "refs/heads/main" ]; then'
mutate "one action unpinned" check_pins "not pinned with a version comment: uses: docker/login-action@v4" "$Y" \
    'docker/login-action@8aa5831fb8d48d8f76594c7ddde61ae58019f550 # v4.8.0' 'docker/login-action@v4'
mutate "pin with no version comment" check_pins "not pinned with a version comment" "$Y" \
    'hadolint/hadolint-action@06be81baf89a55ffd0e24b8f04a4185738dd3387 # v3.5.0' \
    'hadolint/hadolint-action@06be81baf89a55ffd0e24b8f04a4185738dd3387'
mutate "push: not from Tags" check_structure "push: does not read the Tags output" "$Y" \
    "push: \${{ steps.tags.outputs.push == 'true' }}" 'push: true'
mutate "platforms default changed" check_structure "input defaults are" "$Y" \
    'default: "linux/amd64,linux/arm64"' 'default: "linux/amd64"'
mutate "build does not need hadolint" check_structure "build does not need hadolint" "$Y" \
    '    needs: hadolint
' ''
mutate "login always runs" check_structure "login if: is" "$Y" \
    "        if: steps.tags.outputs.push == 'true'
" ''
mutate "no QEMU step" check_structure "does not set up QEMU and Buildx" "$Y" \
    '      - uses: docker/setup-qemu-action@' '      - uses: example/other-action@'
mutate "no Buildx step" check_structure "does not set up QEMU and Buildx" "$Y" \
    '      - uses: docker/setup-buildx-action@' '      - uses: example/other-action@'
# The QEMU step moves to the end of the build job, after build-push.
rm -f "$TMPROOT/broken-order.yml"
if ruby -e '
    t = File.read(ARGV[0])
    q = t[/^      - uses: docker\/setup-qemu-action@.*\n\n/] or abort "text not found"
    t.sub!(q, "")
    File.write(ARGV[1], t + q.chomp)
' "$Y" "$TMPROOT/broken-order.yml"; then
    control "QEMU after build-push" check_structure "$TMPROOT/broken-order.yml" "does not set up QEMU and Buildx"
else
    fail "control QEMU after build-push: the mutation did not apply"
fi
mutate "hadolint dockerfile literal" check_structure "hadolint dockerfile: does not read the input" "$Y" \
    '          dockerfile: ${{ inputs.dockerfile }}' '          dockerfile: Dockerfile'
mutate "build-push file literal" check_structure "build-push file: does not read the input" "$Y" \
    '          file: ${{ inputs.dockerfile }}' '          file: Dockerfile'
mutate "cache-to always writes" check_structure "cache-to: does not depend on the Tags push output" "$Y" \
    "cache-to: \${{ steps.tags.outputs.push == 'true' && 'type=gha,mode=max' || '' }}" 'cache-to: type=gha,mode=max'

D="$CI_DOC"
mutate "doc drops the main row" check_doc "tag table row missing" "$D" \
    '| `push` to `main` | Yes |' '| `push` to `main` | No |'
mutate "doc drops latest from the tag row" check_doc "tag table row missing" "$D" \
    '`X.Y.Z`, `X.Y`, `latest` |' '`X.Y.Z`, `X.Y` |'
mutate "doc drops the host rule" check_doc "host pull-tag rule missing" "$D" \
    'The host must pull `latest` or a version tag' 'The host pulls a tag'
mutate "doc drops the Monitoring example" check_doc "Monitoring example missing" "$D" \
    'from `:main` to `:latest`.' 'to a new tag.'
mutate "doc caller loose tag filter" check_doc "tag filter is not strict" "$D" \
    'tags: ["v[0-9]+.[0-9]+.[0-9]+"]' 'tags: ["v*.*.*"]'
mutate "doc caller group per ref" check_doc "concurrency group is not shared" "$D" \
    "\${{ startsWith(github.ref, 'refs/tags/') && 'release' || github.ref }}" '${{ github.ref }}'
# check_doc reads only the section. Without its heading, the rows in the
# rest of the doc do not count.
mutate "doc section heading renamed" check_doc "no container-image.yml section" "$D" \
    '## `container-image.yml`' '## Container images'

harness_report
