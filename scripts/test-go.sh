#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root/external"

export CRAFTNET_TEST_SEED=${CRAFTNET_TEST_SEED:-12648430}
echo "CraftNet test seed: $CRAFTNET_TEST_SEED"
go test -race ./...

