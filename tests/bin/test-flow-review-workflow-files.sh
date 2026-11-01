#!/bin/bash
#
# Tests for plugins/flow/bin/flow-review-workflow-files: line 1 is the caller,
# then each local `uses: ./...` workflow in the caller (issue #76). Each
# scenario writes a caller file in a temporary git repo. No gh call.
#
# Usage: bash tests/bin/test-flow-review-workflow-files.sh
# Exit code: 0 if all scenarios pass, 1 otherwise.

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/../lib/harness.sh"

REAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REAL_REPO/plugins/flow/bin/flow-review-workflow-files"
if [ ! -x "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found or not executable" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)" || exit 1
CALLER=".github/workflows/claude-code-review.yml"
REUSABLE=".github/workflows/claude-review.yml"

# new_repo <name>
# Makes an empty git repo under $TMPROOT and prints its path.
new_repo() {
    local dir="$TMPROOT/$1"
    mkdir -p "$dir/.github/workflows" || return 1
    git -C "$dir" init -q || return 1
    printf '%s\n' "$dir"
}

# expect <label> <dir> <want-exit> <want-stdout> [args...]
# Runs the script in <dir>.
expect() {
    local label="$1" dir="$2" want_exit="$3" want_out="$4" out status
    shift 4
    out="$(cd "$dir" && "$SCRIPT" "$@" 2>/dev/null)"
    status=$?
    if [ "$status" -eq "$want_exit" ] && [ "$out" = "$want_out" ]; then
        pass "$label"
    else
        fail "$label" "exit: $status (want $want_exit)" "stdout: [$out] (want [$want_out])"
    fi
}

# devkit form: the caller calls the reusable workflow from its own repo.
d="$(new_repo devkit)" || exit 1
cat > "$d/$CALLER" <<'EOF'
jobs:
  claude-review:
    uses: ./.github/workflows/claude-review.yml
EOF
expect "local uses: gives the caller and the reusable workflow" "$d" 0 \
    "$CALLER
$REUSABLE"

mkdir -p "$d/sub/dir"
expect "a subfolder of the repo gives the same list" "$d/sub/dir" 0 \
    "$CALLER
$REUSABLE"

# Caller repo form: the reusable workflow is in another repo.
d="$(new_repo remote)" || exit 1
cat > "$d/$CALLER" <<'EOF'
jobs:
  claude-review:
    uses: unibrain1/devkit/.github/workflows/claude-review.yml@main
EOF
expect "uses: @main in another repo gives the caller only" "$d" 0 "$CALLER"

d="$(new_repo none)" || exit 1
expect "no caller file gives the caller only" "$d" 0 "$CALLER"

d="$(new_repo quoted)" || exit 1
cat > "$d/$CALLER" <<'EOF'
jobs:
  a:
    uses: "./.github/workflows/claude-review.yml"
  b:
    uses: './.github/workflows/other.yaml'  # a trailing comment
EOF
expect "quoted values, .yaml, and a trailing comment" "$d" 0 \
    "$CALLER
$REUSABLE
.github/workflows/other.yaml"

d="$(new_repo commented)" || exit 1
cat > "$d/$CALLER" <<'EOF'
jobs:
  a:
    # uses: ./.github/workflows/old.yml
    uses: unibrain1/devkit/.github/workflows/claude-review.yml@main
EOF
expect "a commented-out uses: line does not count" "$d" 0 "$CALLER"

d="$(new_repo dup)" || exit 1
cat > "$d/$CALLER" <<'EOF'
jobs:
  a:
    uses: ./.github/workflows/claude-review.yml
  b:
    uses: ./.github/workflows/claude-review.yml
EOF
expect "two jobs that call one file give one line" "$d" 0 \
    "$CALLER
$REUSABLE"

d="$(new_repo action)" || exit 1
cat > "$d/$CALLER" <<'EOF'
jobs:
  a:
    steps:
      - uses: ./.github/actions/setup
      - uses: ./.github/workflows/not-a-job.yml
      - uses: actions/checkout@v4
EOF
expect "a step-level uses: does not count" "$d" 0 "$CALLER"

expect "an argument is a usage error" "$TMPROOT" 1 "" extra

mkdir -p "$TMPROOT/not-a-repo"
expect "a folder outside a git work tree gives exit 1 and no list" "$TMPROOT/not-a-repo" 1 ""

# Root can read a file with mode 000, so this case needs a normal user.
if [ "$(id -u)" -ne 0 ]; then
    d="$(new_repo unreadable)" || exit 1
    printf '%s\n' 'jobs:' > "$d/$CALLER"
    chmod 000 "$d/$CALLER"
    expect "an unreadable caller gives exit 1 and no partial list" "$d" 1 ""
    chmod 644 "$d/$CALLER"
fi

harness_report
