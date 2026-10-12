#!/bin/bash
# typeless-autoenter installer: build in place, generate the LaunchAgent, start the service. Safe to re-run; upgrades use it too.
# Usage: ./install.sh [--app <bundle id>]...
#   On first install, writes these apps to the config.json whitelist; an existing config.json is left untouched.
set -euo pipefail
cd "$(dirname "$0")"
DIR="$(pwd -P)"
LABEL="local.typeless-autoenter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

apps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      [ $# -ge 2 ] || { echo "--app needs a Bundle ID" >&2; exit 2; }
      echo "$2" | grep -Eq '^[A-Za-z0-9._-]+$' || { echo "Invalid Bundle ID: $2" >&2; exit 2; }
      apps+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname)" = Darwin ] || { echo "macOS only" >&2; exit 1; }
swiftc --version >/dev/null 2>&1 || {
  echo "swiftc is not available: run xcode-select --install to install the Command Line Tools." >&2
  echo "If they are already installed, try sudo xcodebuild -license accept, or update the Command Line Tools, then re-run this script." >&2
  exit 1
}
case "$DIR" in
  *[\&\<\>\"]*) echo "The directory path contains one of & < > \" -- install from a different directory" >&2; exit 1 ;;
esac
# The background service cannot read files in macOS-protected folders (if it cannot read
# config.json, no app is enabled at all).
# macOS volumes are case-insensitive by default, so ~/desktop reaches the same folder: compare in lower case.
dir_lc="$(printf '%s' "$DIR" | tr '[:upper:]' '[:lower:]')"
home_lc="$(printf '%s' "$HOME" | tr '[:upper:]' '[:lower:]')"
case "$dir_lc" in
  "$home_lc/desktop"|"$home_lc/desktop/"*|"$home_lc/documents"|"$home_lc/documents/"*|"$home_lc/downloads"|"$home_lc/downloads/"*|"$home_lc/library/mobile documents/"*|"$home_lc/library/cloudstorage/"*)
    echo "This directory is in a macOS protected location (Desktop / Documents / Downloads / iCloud): $DIR" >&2
    echo "The background service cannot read files there. Move the whole directory elsewhere, e.g. ~/Developer/typeless-autoenter, then run ./install.sh again." >&2
    exit 1 ;;
esac
if [ ! -d /Applications/Typeless.app ] && [ ! -d "$HOME/Applications/Typeless.app" ]; then
  echo "Warning: Typeless.app not found; continuing anyway (ignore this if it lives elsewhere)"
fi

echo "==> Building"
# Build into a temp directory first, then replace: no half-written binary is left behind,
# and the code-signing identifier stays typeless-autoenter.
mkdir -p .build
swiftc -O main.swift -o .build/typeless-autoenter -lsqlite3
mv .build/typeless-autoenter typeless-autoenter

if [ ! -f config.json ]; then
  echo "==> Creating config.json"
  if [ ${#apps[@]} -gt 0 ]; then
    n=${#apps[@]}; i=0
    {
      echo '{'
      echo '  "apps": ['
      for a in "${apps[@]}"; do
        i=$((i + 1)); sep=","; [ "$i" -eq "$n" ] && sep=""
        printf '    "%s"%s\n' "$a" "$sep"
      done
      echo '  ]'
      echo '}'
    } > config.json
  else
    cp config.example.json config.json
  fi
elif [ ${#apps[@]} -gt 0 ]; then
  echo "Note: config.json already exists and was left untouched; --app was ignored. Edit config.json directly."
fi

# The first start after a (re)install shows the Accessibility prompt once.
rm -f .access-prompted
# Switch to a fresh log file so the self-check only sees records from this start,
# not the permission state left behind by the previous binary.
if [ -f autoenter.log ]; then mv -f autoenter.log autoenter.log.1; fi

echo "==> Registering and starting the service ($LABEL)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/typeless-autoenter</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$DIR/autoenter.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/autoenter.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
loaded=0
err=""
for _ in 1 2 3 4 5; do
  if err="$(launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>&1)"; then loaded=1; break; fi
  sleep 1
done
if [ "$loaded" -ne 1 ]; then
  echo "launchctl bootstrap failed: $err" >&2
  echo "Check: System Settings → General → Login Items & Extensions, and make sure typeless-autoenter is not switched off." >&2
  echo "You can also run launchctl print-disabled gui/$UID_NUM | grep typeless to see whether it is disabled." >&2
  exit 1
fi
# Wait for the service to write its start record (up to 10 seconds).
for _ in $(seq 1 20); do
  grep -qs "started," autoenter.log && break
  sleep 0.5
done

echo "==> Self-check"
./typeless-autoenter doctor || true

cat <<EOF

Next steps:
  1. Grant Accessibility permission: System Settings → Privacy & Security → Accessibility,
     then switch on typeless-autoenter.
     If no prompt appeared, or an old entry is already listed (entries go stale after an upgrade):
     remove it with −, then add this file with +
     $DIR/typeless-autoenter
  2. Put the apps that should get the automatic Enter into the apps array in $DIR/config.json.
     Run ./typeless-autoenter list-apps to see the Bundle IDs of running apps.
  3. Run ./typeless-autoenter doctor at any time to check the status. Log: $DIR/autoenter.log
EOF
