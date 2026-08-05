# Contributing to this repository

## Pure Lua Requirement

This library **MUST** work in pure Lua environment, without depending any other Lua packages.

There can be dependency requirement in order to test this library, but the library itself should not have any mandatory dependency.

Optional dependency is allowed, but the existence of it must be checked, such as LibStub.

## CI

All CI running as Github workflow should be passing.

See comments in the config files in [.github/workflows](.github/workflows) for detail.

### The differential gate

A pull request that touches `LibDeflateGuard.lua` or `tests/FuzzTest.lua` is
compared, call for call, against the latest release tag: every public decode
entry point must return an identical tuple for the same input. A divergence
fails `differential_gate` and blocks the merge.

Some divergences are intended. v1.2.0 made `DecodeForPrint` refuse a length no
encoder can emit, so against v1.1.2 it correctly reports that a string which
used to decode now returns `nil, invalid_print`. When the change is deliberate,
a maintainer applies the `differential-divergence-ok` label to the pull
request. The gate re-runs, still prints the divergence in the log and in the
job summary, and passes. Removing the label makes it block again.

Reproduce the comparison locally. Resolve the reference the same way the
workflow does, rather than naming a tag that goes stale at the next release:

```sh
tag="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
git worktree add ../libdeflateguard-reference "${tag}"
LIBDEFLATEGUARD_FUZZ_REFERENCE=../libdeflateguard-reference/LibDeflateGuard.lua \
  LIBDEFLATEGUARD_FUZZ_SEED=1234 \
  LIBDEFLATEGUARD_FUZZ_ITERATIONS=25 \
  lua tests/FuzzTest.lua
```

### The nightly soak

`fuzz_soak` runs `tests/FuzzTest.lua` every night with a raised iteration count
and a fresh seed. The seed is printed in the log and in the job summary, on
success and on failure. To reproduce a failing night, re-run the workflow by
hand through `workflow_dispatch` with that seed, or run it locally:

```sh
LIBDEFLATEGUARD_FUZZ_SEED=<seed from the failing run> \
  LIBDEFLATEGUARD_FUZZ_ITERATIONS=<iterations from the failing run> \
  lua tests/FuzzTest.lua
```

### Version numbers

Four version sites are hand-edited and must be changed together: the
`LibDeflateGuard.lua` header banner on line 2, `_VERSION`, `_COPYRIGHT`, and
the `version` and `tag` fields of
`rockspecs/libdeflateguard-<version>-1.rockspec`. `version_check` asserts they
agree on every push and pull request, and on a tag push that they also agree
with the tag. Run `tools/check_version_consistency.sh` before pushing a
release.

## Testing

Test code for your features are required. 100% Code coverage is recommended.

Read [tests/README.md](tests/README.md) for detail.

## Format

All hand written code in this repo should be formatted by an auto
formatter before committed to the repository.
There should be no format-only changes in the Pull Request.

Read [dev_docs/format.md](dev_docs/format.md) for detail.

## Linting

Lua code in LibDeflateGuard should not have lint warnings.

Read [dev_docs/lint.md](dev_docs/lint.md) for detail.

## IDE

Share my IDE setup as a reference.

Read [dev_docs/ide.md](dev_docs/ide.md) for detail.
