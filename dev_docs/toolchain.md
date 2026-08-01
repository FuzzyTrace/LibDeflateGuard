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

## Windows quirks worth knowing

Two version pins in `check_format.yml` cannot be met on a current Python.
`yapf` 0.31.0 imports `lib2to3`, which was removed from the standard library
in Python 3.13. A modern yapf produces identical output on this repository's
single Python file. `clang-format` likewise floats, and also produces no diff
here.

Lua for Windows ships a directory named `lua` beside `lua.exe`. Git Bash
resolves the directory first and then reports that `lua` is not a command. Use
`lua.exe` in Git Bash. Cmd and PowerShell are unaffected.
