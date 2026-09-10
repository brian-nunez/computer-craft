#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"

if [[ -n "${LUA_BIN:-}" ]]; then
  lua_command=$LUA_BIN
elif command -v lua5.2 >/dev/null 2>&1; then
  lua_command=lua5.2
elif command -v lua >/dev/null 2>&1; then
  lua_command=lua
elif command -v luajit >/dev/null 2>&1; then
  lua_command=luajit
else
  echo "test-lua: no Lua interpreter found" >&2
  exit 1
fi

test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/craftnet-lua-tests.XXXXXX")
cleanup() {
  rm -rf -- "$test_tmp_dir"
}
trap cleanup EXIT

export CRAFTNET_TEST_TMPDIR=$test_tmp_dir
export CRAFTNET_TEST_SEED=${CRAFTNET_TEST_SEED:-12648430}

mapfile -t test_files < <(find tests/lua -maxdepth 1 -type f -name '*_test.lua' -print | sort)
if [[ ${#test_files[@]} -eq 0 ]]; then
  echo "test-lua: no test files found" >&2
  exit 1
fi

echo "Lua: $($lua_command -v 2>&1 | head -n 1)"
echo "CraftNet test seed: $CRAFTNET_TEST_SEED"
"$lua_command" tests/lua/test_runner.lua "${test_files[@]}"

