#!/usr/bin/env bash
set -euo pipefail

# The fixture catalog is generated. Regenerating it must reproduce the checked-in
# files byte for byte, so that a change to the generator can never drift away
# from the catalog both languages are tested against.

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

regenerated=$(mktemp -d "${TMPDIR:-/tmp}/craftnet-fixtures.XXXXXX")
cleanup() {
  rm -rf -- "$regenerated"
}
trap cleanup EXIT

cd "$project_root/external"
go run ./cmd/fixturegen "$regenerated" >/dev/null

if ! diff -ru "$project_root/spec/protocol/v1" "$regenerated"; then
  echo "check-fixtures: spec/protocol/v1 is stale; run bash scripts/generate-fixtures.sh" >&2
  exit 1
fi
echo "protocol fixture catalog is up to date"
