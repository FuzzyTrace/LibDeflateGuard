#!/bin/bash
# Reformat Lua files in this repository
# Tool used is LuaFormatter: https://github.com/Koihik/LuaFormatter
# For tool installation and version used, see .github/workflows/format.yml
# This script is also used in CI. Edit with CAUTION!

set -euxo pipefail

cd "$(git rev-parse --show-toplevel)"
# LibCompress is vendored third-party code. Keep its source form intact rather
# than rewriting it with our formatter. .luacheckrc excludes it from linting for
# the same reason.
git ls-files -c -o --exclude-standard -z '*.lua' |
  grep -zvE '^tests/LibCompress/' |
  xargs -0 -r -P 0 -t -n 1 -I {} bash -c 'if [[ -e "{}" ]]; then lua-format -i "{}"; fi'
