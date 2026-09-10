#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$project_root/scripts/test-lua.sh"
bash "$project_root/scripts/test-fixtures.sh"
bash "$project_root/scripts/test-catalog.sh"
bash "$project_root/scripts/test-go.sh"
