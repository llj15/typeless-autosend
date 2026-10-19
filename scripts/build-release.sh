#!/bin/bash
# Build a self-contained macOS ARM binary distribution from a clean commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  echo 'Usage: scripts/build-release.sh v<major>.<minor>.<patch> [output-directory]'
  echo 'Requires macOS, Xcode Command Line Tools and a clean Git working tree.'
  exit 0
fi
[ $# -ge 1 ] && [ $# -le 2 ] && [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'Usage: scripts/build-release.sh v<major>.<minor>.<patch> [output-directory]' >&2; exit 2;
}
[ "$(uname -s)" = Darwin ] || { echo 'Build this release on macOS.' >&2; exit 1; }
cd "$ROOT"
[ -z "$(git status --porcelain)" ] || {
  echo 'Commit all release changes before building; BUILD_INFO must identify the exact source.' >&2; exit 1;
}
VERSION="$1"
COMMIT="$(git rev-parse HEAD)"
mkdir -p "${2:-$ROOT/dist}"
OUTPUT_DIR="$(cd "${2:-$ROOT/dist}" && pwd -P)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/typeless-autosend-release.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
NAME="typeless-autosend-$VERSION-macos-arm64"
BUNDLE="$STAGING/$NAME"
mkdir -p "$BUNDLE/bin" "$BUNDLE/support/skill"

echo "==> Building $VERSION ($COMMIT), arm64 / macOS 15+"
swiftc -O -target arm64-apple-macosx15.0 "$ROOT"/*.swift \
  -o "$BUNDLE/bin/typeless-autosend" -lsqlite3
[ "$(lipo -archs "$BUNDLE/bin/typeless-autosend")" = arm64 ] || {
  echo 'Unexpected binary architecture.' >&2; exit 1;
}
codesign --force --sign - --identifier typeless-autosend "$BUNDLE/bin/typeless-autosend"
codesign --verify --strict "$BUNDLE/bin/typeless-autosend"
"$BUNDLE/bin/typeless-autosend" -h >/dev/null

cp "$ROOT/scripts/install-release.sh" "$BUNDLE/install.sh"
cp "$ROOT/install.sh" "$BUNDLE/support/install-service.sh"
cp "$ROOT/uninstall.sh" "$ROOT/config.example.json" "$BUNDLE/support/"
cp "$ROOT/skill/SKILL.md" "$BUNDLE/support/skill/"
sed "s/@VERSION@/$VERSION/g" "$ROOT/scripts/README-release.md" > "$BUNDLE/README.md"
cat > "$BUNDLE/support/BUILD_INFO" <<EOF
version=$VERSION
commit=$COMMIT
architecture=arm64
minimumMacOS=15.0
builtAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 755 "$BUNDLE/install.sh" "$BUNDLE/support/install-service.sh" "$BUNDLE/support/uninstall.sh"
(
  cd "$BUNDLE"
  shasum -a 256 bin/typeless-autosend install.sh support/install-service.sh \
    support/uninstall.sh support/config.example.json support/skill/SKILL.md \
    support/BUILD_INFO README.md > SHA256SUMS
)
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/$NAME.tar.gz" -C "$STAGING" "$NAME"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$NAME.tar.gz" > SHA256SUMS
)
echo "==> Ready: $OUTPUT_DIR/$NAME.tar.gz"
echo "==> Checksum: $OUTPUT_DIR/SHA256SUMS"
