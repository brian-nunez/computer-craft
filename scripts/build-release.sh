#!/usr/bin/env bash
# Build checksummed craftnetd binaries for a release.
#
# One static, CGo-free binary per platform, each one stamped with the version it
# claims to be, and one SHA-256 manifest covering all of them. A build that is
# not given a version says `0.1.0-dev`, because a binary must never name a
# release nobody cut.
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root/external"

version=${1:-}
if [[ -z $version ]]; then
  echo "usage: build-release.sh VERSION   (for example: build-release.sh 0.1.0)" >&2
  exit 2
fi
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "build-release: '$version' is not a semantic version" >&2
  exit 2
fi

out=$project_root/dist/$version
rm -rf -- "$out"
mkdir -p -- "$out"

# CGo is off everywhere: the SQLite driver is pure Go, and that is what keeps
# craftnetd one file with nothing to install alongside it.
export CGO_ENABLED=0

platforms=(
  "linux/amd64"
  "linux/arm64"
  "darwin/amd64"
  "darwin/arm64"
  "windows/amd64"
)

echo "craftnetd $version"
for platform in "${platforms[@]}"; do
  goos=${platform%/*}
  goarch=${platform#*/}
  name=craftnetd-$version-$goos-$goarch
  [[ $goos == windows ]] && name=$name.exe

  echo "  building $name"
  GOOS=$goos GOARCH=$goarch go build \
    -trimpath \
    -ldflags "-s -w -X github.com/brian-nunez/computer-craft/external/internal/buildinfo.Version=$version" \
    -o "$out/$name" \
    ./cmd/craftnetd
done

cd "$out"
sha256sum ./* > SHA256SUMS
echo
echo "wrote $out"
cat SHA256SUMS
