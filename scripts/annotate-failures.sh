#!/usr/bin/env bash
# Turn compiler errors and failed test assertions in build/test logs into
# GitHub Actions error annotations, so they show up on the run summary.
set -uo pipefail
for log in "$@"; do
  [ -f "$log" ] || continue
  grep -E "error:|failed \(|XCTAssert|Fatal error" "$log" \
    | grep -v "^error: fatalError$" \
    | sort -u | head -50 \
    | while IFS= read -r line; do
        if [[ "$line" =~ ^(/[^:]+):([0-9]+):([0-9]+):\ error:\ (.*)$ ]]; then
          file="${BASH_REMATCH[1]#"$PWD/"}"
          echo "::error file=${file},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
        else
          echo "::error::${line}"
        fi
      done
done
exit 0
