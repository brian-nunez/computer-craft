#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root/external"
go run ./cmd/fixturegen "$project_root/spec/protocol/v1"
