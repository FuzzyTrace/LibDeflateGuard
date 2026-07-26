#!/bin/bash
# Generate an embed-source package in .release/libdeflateguard-VERSION.zip.
# VERSION is the commit id if not on a tag, otherwise it is the tag name.
# The archive is intentionally not a standalone WoW addon.

set -euxo pipefail

ErrorHandler() {
  local exit_code="$1"
  local parent_lineno="$2"
  echo "error on or near line ${parent_lineno}; exiting with status ${exit_code}"
  exit "${exit_code}"
}

GetFilename() {
  local commit="$(git rev-parse HEAD)"
  local prefix="libdeflateguard-"
  local tag="$(git describe --tags --exact-match ${commit} 2>/dev/null)"
  if [[ -n "${tag}" ]]; then
    echo "${prefix}${tag}"
  else
    echo "${prefix}${commit}"
  fi
}

MakePackage() {
  local filename="$1"
  if [[ -z "${filename}" ]]; then
    echo "No filename specified" >&2
    return 1
  fi
  local staging=".release/LibDeflateGuard"
  mkdir -p "${staging}"
  cp LibDeflateGuard.lua LibDeflateGuard.xml LICENSE.txt README.md changelog.md \
    "${staging}/"
  git rev-parse HEAD >"${staging}/COMMIT"
  (
    cd .release
    zip -9 -r "${filename}.zip" LibDeflateGuard
  )
}

main() {
  trap 'ErrorHandler $? ${LINENO}' ERR
  cd "$(git rev-parse --show-toplevel)"
  rm -rf .release
  mkdir -p .release
  local filename="$(GetFilename)"
  MakePackage "${filename}"
}

main
