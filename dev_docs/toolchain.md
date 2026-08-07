# Local validation toolchain

Everything CI runs can be run locally. This document records how to get there
on Windows, where it is least obvious. On Linux and macOS the CI workflows are
themselves the instructions and mostly work as written.

Use the workflow files as the source of truth for versions:
[lua_test.yml](../.github/workflows/lua_test.yml),
[lua_lint.yml](../.github/workflows/lua_lint.yml) and
[check_format.yml](../.github/workflows/check_format.yml).

## Why bother

Without a C toolchain the inherited suite cannot build its reference programs,
and 77 of its 139 tests fail for reasons that have nothing to do with the
library. That failure mode looks alarming and trains people to ignore the
suite. With the toolchain in place the full suite passes locally in about
eight minutes under LuaJIT.

## What you need

| Purpose                        | Tool                                                 |
| ------------------------------ | ---------------------------------------------------- |
| Reference compressors, C rocks | A C compiler and make                                |
| `tests/Test.lua`               | zlib, `puff`, `zdeflate`, luaunit                    |
| `tests/BenchTest.lua`          | Nothing; a reference module is optional              |
| `tools/lint_lua_code.sh`       | luacheck, which needs luafilesystem and a C compiler |
| `tools/format_lua.sh`          | LuaFormatter                                         |
| `tools/format_doc.sh`          | prettier                                             |
| `tools/format_sh.sh`           | shfmt                                                |
| `tools/format_c.sh`            | clang-format                                         |
| `tools/format_py.sh`           | yapf                                                 |
| `tools/format_pwsh.sh`         | PowerShell 7 and PowerShell-Beautifier               |

## Windows setup

Everything below installs per user. None of it needs an administrator shell.

A MinGW-w64 toolchain is the piece everything else waits on. Any recent build
works; the WinLibs MSVCRT flavour matches what CI uses closely enough:

```sh
winget install -e --id BrechtSanders.WinLibs.POSIX.MSVCRT --scope user
```

Reference compressors, following
[install_compressor.sh](../.github/workflows/script/install_compressor.sh):

```sh
curl -L https://github.com/madler/zlib/archive/refs/tags/v1.3.2.tar.gz | tar xz
cd zlib-1.3.2 && mingw32-make -f win32/Makefile.gcc
export ZLIB_PATH="$(pwd)"
cd /path/to/LibDeflateGuard/tests && mingw32-make
```

That produces `tests/puff.exe` and `tests/zdeflate.exe`. Both are gitignored.
Put the `tests` directory on PATH, or most of `tests/Test.lua` will fail.

Lua rocks, against whichever interpreter you use:

```sh
luarocks --lua-version 5.1 --lua-dir /path/to/luajit install --local luaunit 3.4-1
luarocks --lua-version 5.1 --lua-dir /path/to/luajit install --local luacheck
```

LuaFormatter has no Windows package, so build the commit CI pins:

```sh
git clone --recurse-submodules https://github.com/Koihik/LuaFormatter.git
cd LuaFormatter && git checkout abfe1646162338b7361f35733fd48d7d10cba69e
mkdir build && cd build
cmake .. -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release && cmake --build . -j
```

The rest come from ordinary package managers: `npm install -g prettier@2.2.1`,
`pip install --user clang-format yapf`, `winget install -e --id mvdan.shfmt`,
and `Install-Module PowerShell-Beautifier -RequiredVersion 1.2.5 -Scope CurrentUser`.

Extra interpreters build from source in seconds each, which is worth doing
because the guard suites are fast enough to run on all of them:

```sh
curl -L https://www.lua.org/ftp/lua-5.4.3.tar.gz | tar xz
cd lua-5.4.3 && mingw32-make mingw
```

Copy `src/lua.exe` and `src/lua54.dll` somewhere on PATH together. The DLL has
to sit next to the executable.

## Running it

```sh
export ZLIB_PATH=/path/to/zlib-1.3.2
export PATH="/path/to/LibDeflateGuard/tests:$PATH"
export LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;./?.lua;;"

lua tests/GuardTest.lua
lua tests/FuzzTest.lua
lua tests/Test.lua --verbose --shuffle
luacheck -g -u .
tools/format_all.sh && git diff --exit-code
```

## Benchmarking against a reference module

`tests/BenchTest.lua` needs no reference programs, no rocks and no C
toolchain. Run alone it prints absolute numbers for the six migration-relevant
decode paths and for the four saturation shapes that size a policy:

```sh
luajit -joff tests/BenchTest.lua
```

Point `LIBDEFLATEGUARD_BENCH_REFERENCE` at another module to get a comparison
table. It accepts either an upstream `LibDeflate.lua` or an older
`LibDeflateGuard.lua` and adapts the call shape to whichever it is, so the
same command answers both "what did this fork cost against upstream" and "did
this branch regress against the last release":

```sh
git worktree add ../upstream-baseline afc3b78d12fb3bcfa6b21e5332031ad3d7572e19
LIBDEFLATEGUARD_BENCH_REFERENCE=../upstream-baseline/LibDeflate.lua \
  luajit tests/BenchTest.lua
```

Three environment variables configure it, named to match the ones
`tests/FuzzTest.lua` already uses:

| Variable                          | Default | Meaning                          |
| --------------------------------- | ------- | -------------------------------- |
| `LIBDEFLATEGUARD_BENCH_REFERENCE` | unset   | Reference module to compare with |
| `LIBDEFLATEGUARD_BENCH_ROUNDS`    | 21      | Alternated A/B rounds per shape  |
| `LIBDEFLATEGUARD_BENCH_SEED`      | 1234    | Corpus seed                      |

The reference is loaded with `dofile` and has to return a table. The harness
dispatches on its `_NAME` rather than passing an older module arguments
upstream would read as something else, which is the footgun the v1.1.2 fix was
about. Unset or empty, it benchmarks this module alone and prints absolute
numbers, which is all the saturation shapes need.

The reported figure for each shape is the median of the rounds, with the
spread printed beside it. Rounds must be a whole number of at least three,
which is the floor for that spread to describe anything.

The seed must be a whole number below 2147483647, and the harness exits 1
rather than run anything if it is not: a seed outside that range means one
value under LuaJIT's doubles and another under 5.4's integers, and a published
number has to come from a corpus that is byte for byte the same everywhere.
The generator is the private MINSTD `tests/FuzzTest.lua` uses, and the harness
checks it against fixed draws before building any corpus rather than assuming
it.

Use `luajit -joff` for any number that goes into a document. It is the World
of Warcraft interpreter proxy every figure this repository has published was
taken on, and it is also far more repeatable: with the JIT on, two modules
this similar share one trace cache and a delta moves further between runs than
the spread the harness reports within a run. The harness prints that warning
itself when it finds the JIT on, and prints the interpreter and `jit.status()`
either way, so a pasted result carries the conditions it was taken under.

### Reading the output

Every timing figure is a median, with a `spread` beside it. The spread is half
the p10 to p90 band of the samples, as a fraction of the median. Deciles
rather than max minus min, because a plain range is one outlier wide — a
single collection or a scheduling hiccup sets it — and would declare every
result unmeasurable.

Which samples those are depends on the mode. Run alone, the spread is the
spread of the round times themselves, which is what an absolute number is
reproducible to on this machine. Run against a reference, the delta is the
median of the per-round ratios rather than the ratio of the two medians, and
the spread printed beside it is that paired ratio's own spread, not either
module's. Dividing inside a round cancels load common to both modules, so it
is a tighter and more honest floor for a comparison than either module's
absolute spread, which is dominated by whatever else the machine is doing.

Printing that floor is the point. A delta smaller than its own spread is the
floor talking rather than the code, and the harness says so in words: every
such row gets a `#` line under the table naming it and telling you to report
it as about flat. A row missing from those notes is one whose delta cleared
its spread on that run. Do not quote a figure for a row that did not.

`alloc/call` is bytes allocated per call, measured with the collector stopped
so that nothing is reclaimed mid-call. It therefore counts what the call threw
away as well as what it kept, and it is not peak heap — peak heap cannot be
sampled from inside Lua without instrumenting the module. What it does bound
is how much one call can add to the heap. It is the reproducible half of the
pair: allocation figures repeat exactly across runs on which the timings move.
In comparison mode it gets its own table rather than a column.

Nothing in it fails on a timing result, however bad. The byte-identical
cross-checks run before any timing and are the only thing that can fail the
run.

## Windows quirks worth knowing

Two version pins in `check_format.yml` cannot be met on a current Python.
`yapf` 0.31.0 imports `lib2to3`, which was removed from the standard library
in Python 3.13. A modern yapf produces identical output on this repository's
single Python file. `clang-format` likewise floats, and also produces no diff
here.

Lua for Windows ships a directory named `lua` beside `lua.exe`. Git Bash
resolves the directory first and then reports that `lua` is not a command. Use
`lua.exe` in Git Bash. Cmd and PowerShell are unaffected.
