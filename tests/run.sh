#!/bin/bash
#
# Runs every tests/**/test-*.sh file and prints one PASS or FAIL line for each.
# It exits 1 when any file fails. Test output is hidden for a passing file and
# shown for a failing file.
#
# Usage: bash tests/run.sh
#
# Works on macOS bash 3.2 and on Ubuntu bash 5, so it uses no mapfile and no
# associative array.

set -u

tests_dir="$(cd "$(dirname "$0")" && pwd)"
failed=0
total=0
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

while IFS= read -r test_file; do
    total=$((total + 1))
    rel="${test_file#"${tests_dir}"/}"
    if bash "$test_file" > "$output_file" 2>&1; then
        echo "PASS: ${rel}"
    else
        failed=$((failed + 1))
        echo "FAIL: ${rel}"
        sed 's/^/      /' "$output_file"
    fi
done < <(find "$tests_dir" -type f -name 'test-*.sh' | LC_ALL=C sort)

echo ""
echo "${total} file(s) run, ${failed} failed."
[ "$failed" -eq 0 ]
