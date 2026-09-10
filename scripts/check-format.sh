#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"

unformatted=$(gofmt -l external)
if [[ -n "$unformatted" ]]; then
  echo "Go files require gofmt:" >&2
  echo "$unformatted" >&2
  exit 1
fi

git diff --check

