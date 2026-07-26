#!/bin/bash
# Reformat C/C++ files in this repository
# Tool used is clang-format
# For tool installation and version used, see .github/workflows/format.yml
# This script is also used in CI. Edit with CAUTION!

set -euxo pipefail

cd "$(git rev-parse --show-toplevel)"
# fields.c and puff.c are licensed upstream compatibility fixtures. Keep their
# source form intact instead of rewriting them with the runner's clang version.
git ls-files -c -o --exclude-standard -z '*.c' '*.cc' '*.cpp' |
  grep -zvE '^(tests/data/3rdparty/fields\.c|tests/puff\.c)$' |
  xargs -0 -r -P 0 -t -n 1 clang-format -i
