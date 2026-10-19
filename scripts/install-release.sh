#!/bin/bash
# Install the precompiled macOS ARM release; no Swift compiler is needed.
set -euo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
case "${1:-}" in
  -h|--help)
    echo 'Usage: ./install.sh [--app <bundle.id>]...'
    echo 'Install in ~/typeless-autosend, or upgrade the registered installation in place.'
    echo 'Existing configuration is preserved. Adding apps is optional.'
    exit 0 ;;
esac
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
  echo 'This release requires macOS on Apple Silicon (ARM64).' >&2; exit 1;
}
OS_VERSION="$(sw_vers -productVersion)"
[ "${OS_VERSION%%.*}" -ge 15 ] || {
  echo 'This release requires macOS 15 or later.' >&2; exit 1;
}
cd "$BUNDLE_DIR"
shasum -a 256 --check SHA256SUMS || {
  echo 'Release checksum verification failed. Download and extract the archive again.' >&2
  exit 1
}
INSTALL_DIR=""
for label in local.typeless-autosend local.typeless-autoenter; do
  plist="$HOME/Library/LaunchAgents/$label.plist"
  [ -e "$plist" ] || continue
  registered_binary="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")" || {
    echo "Cannot read the existing registration: $plist. Repair it before upgrading." >&2; exit 1;
  }
  registered_dir="$(cd "$(dirname "$registered_binary")" && pwd -P)" || {
    echo "The existing installation directory is missing. Restore it before upgrading: $registered_binary" >&2; exit 1;
  }
  if [ -n "$INSTALL_DIR" ] && [ "$INSTALL_DIR" != "$registered_dir" ]; then
    echo 'Two different installations are registered. Resolve the conflicting LaunchAgents before upgrading.' >&2
    exit 1
  fi
  INSTALL_DIR="$registered_dir"
done
TYPELESS_INSTALL_DIR="${INSTALL_DIR:-$HOME/typeless-autosend}" \
TYPELESS_INSTALL_BINARY="$BUNDLE_DIR/bin/typeless-autosend" \
  /bin/bash "$BUNDLE_DIR/support/install-service.sh" "$@"
