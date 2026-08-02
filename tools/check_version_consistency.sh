#!/bin/bash
# Check that every hand-edited version site in this repository agrees.
#
# A release carries four version sites and nothing ties them together:
#
#   1. LibDeflateGuard.lua line 2, the header banner
#   2. LibDeflateGuard.lua _VERSION
#   3. LibDeflateGuard.lua _COPYRIGHT
#   4. rockspecs/libdeflateguard-<version>-1.rockspec, both version and tag
#
# v1.1.1 was a release whose only source change was those strings, which is
# exactly the failure mode this prevents.
#
# Usage:
#   tools/check_version_consistency.sh          check the sites agree
#   tools/check_version_consistency.sh v1.2.3   also check they match a tag
#
# The tag argument accepts "v1.2.3", "1.2.3" or "refs/tags/v1.2.3", because
# the value CI has to hand differs by event.
#
# This script is also used in CI. Edit with CAUTION!

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

module="LibDeflateGuard.lua"
failures=0

Fail() {
  echo "version check: $*" >&2
  failures=$((failures + 1))
}

# Line 2 of the module is the LDoc banner: "LibDeflateGuard 1.1.2 <br>".
banner="$(sed -n '2s/^LibDeflateGuard \([0-9][0-9A-Za-z.-]*\) <br>$/\1/p' \
  "${module}" || true)"

# LibDeflateGuard._VERSION = "1.1.2"
version="$(sed -n 's/^ *LibDeflateGuard\._VERSION = "\([^"]*\)".*$/\1/p' \
  "${module}" || true)"

# _COPYRIGHT is assigned on the line after its name, so read a small window
# rather than a single line. Only the assignment carries the literal string;
# the two later mentions of _COPYRIGHT just print the variable.
copyright="$(grep -A 2 'LibDeflateGuard\._COPYRIGHT' "${module}" |
  sed -n 's/.*"LibDeflateGuard \([0-9][0-9A-Za-z.-]*\), based on .*/\1/p' ||
  true)"

if [[ -z "${banner}" ]]; then
  Fail "cannot parse the version banner on line 2 of ${module}"
fi
if [[ -z "${version}" ]]; then
  Fail "cannot parse LibDeflateGuard._VERSION in ${module}"
fi
if [[ -z "${copyright}" ]]; then
  Fail "cannot parse LibDeflateGuard._COPYRIGHT in ${module}"
fi
if [[ "${failures}" -gt 0 ]]; then
  echo "version check: the module version sites could not be read, so" \
    "nothing else can be checked against them" >&2
  exit 1
fi

# _VERSION is the canonical one. Everything else is compared to it.
if [[ "${banner}" != "${version}" ]]; then
  Fail "${module} line 2 says ${banner}, _VERSION says ${version}"
fi
if [[ "${copyright}" != "${version}" ]]; then
  Fail "${module} _COPYRIGHT says ${copyright}, _VERSION says ${version}"
fi

# The rockspec for the current version must exist, and it must also be the
# newest one in the directory. Checking only that the named file exists would
# pass a release that added rockspecs/...-1.1.3-1.rockspec and forgot to bump
# _VERSION, because the 1.1.2 rockspec is still sitting there.
rockspec="rockspecs/libdeflateguard-${version}-1.rockspec"
if [[ ! -e "${rockspec}" ]]; then
  Fail "_VERSION is ${version} but ${rockspec} does not exist"
else
  rock_version="$(sed -n 's/^version = "\([^"]*\)".*$/\1/p' "${rockspec}" ||
    true)"
  rock_tag="$(sed -n 's/^ *tag = "\([^"]*\)".*$/\1/p' "${rockspec}" || true)"

  if [[ "${rock_version}" != "${version}-1" ]]; then
    Fail "${rockspec} version is '${rock_version}', expected '${version}-1'"
  fi
  if [[ "${rock_tag}" != "v${version}" ]]; then
    Fail "${rockspec} tag is '${rock_tag}', expected 'v${version}'"
  fi
fi

newest_rockspec="$(printf '%s\n' rockspecs/libdeflateguard-*-1.rockspec |
  sort -V | tail -n 1 || true)"
if [[ -n "${newest_rockspec}" && "${newest_rockspec}" != "${rockspec}" ]]; then
  Fail "the newest rockspec is ${newest_rockspec}, but _VERSION is ${version}"
fi

# On a tag push the sites must also agree with the tag being released.
if [[ "$#" -gt 0 && -n "${1}" ]]; then
  tag="${1#refs/tags/}"
  echo "version check: comparing against tag ${tag}"
  if [[ "${tag#v}" != "${version}" ]]; then
    Fail "tag ${tag} does not match _VERSION ${version}"
  fi
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "version check: ${failures} mismatch(es) found. All four sites are" \
    "hand-edited and must be updated together." >&2
  exit 1
fi

echo "version check: all version sites agree on ${version}"
echo "  ${module} line 2   ${banner}"
echo "  _VERSION           ${version}"
echo "  _COPYRIGHT         ${copyright}"
echo "  ${rockspec}"
echo "    version          ${rock_version}"
echo "    tag              ${rock_tag}"
