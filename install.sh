#!/bin/bash
# typeless-autosend installer: build from source or install a release binary, register and start the service. Safe to re-run.
# Usage: ./install.sh [--app <bundle id>]...
#   On first install, writes these apps to the config.json whitelist; an existing config.json is left untouched.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DIR="${TYPELESS_INSTALL_DIR:-$SOURCE_DIR}"
PREBUILT_BINARY="${TYPELESS_INSTALL_BINARY:-}"
if [ -d "$DIR" ]; then DIR="$(cd "$DIR" && pwd -P)"; fi
LABEL="local.typeless-autosend"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
LEGACY_LABEL="local.typeless-autoenter"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_LINK="$HOME/.local/bin/typeless-autoenter"
LEGACY_BINARY="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LEGACY_PLIST" 2>/dev/null || true)"
REMOVE_LEGACY_BINARY=0
if [ "$LEGACY_BINARY" = "$DIR/typeless-autoenter" ] ||
   { [ -n "$LEGACY_BINARY" ] && [ ! -e "$LEGACY_BINARY" ] &&
     [ -L "$LEGACY_LINK" ] && [ "$(readlink "$LEGACY_LINK")" = "$LEGACY_BINARY" ]; }; then
  REMOVE_LEGACY_BINARY=1
fi

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

# A separate checkout has separate settings and a separate instance lock. Upgrade
# in place, or move the whole existing directory, rather than silently resetting it.
for registered_plist in "$LEGACY_PLIST" "$PLIST"; do
  registered_binary="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$registered_plist" 2>/dev/null || true)"
  if [ -n "$registered_binary" ] && [ -d "$(dirname "$registered_binary")" ] &&
     [ "$(cd "$(dirname "$registered_binary")" && pwd -P)" != "$DIR" ]; then
    echo "An existing installation is registered in $(dirname "$registered_binary"). Run install.sh there, or move that whole directory here first, to preserve its configuration and state." >&2
    exit 1
  fi
done

[ "$(uname)" = Darwin ] || { echo "macOS only" >&2; exit 1; }
if [ -z "$PREBUILT_BINARY" ]; then
  swiftc --version >/dev/null 2>&1 || {
    echo "swiftc is not available: run xcode-select --install to install the Command Line Tools." >&2
    echo "If they are already installed, try sudo xcodebuild -license accept, or update the Command Line Tools, then re-run this script." >&2
    exit 1
  }
else
  [ -x "$PREBUILT_BINARY" ] || { echo "Release binary is missing or not executable: $PREBUILT_BINARY" >&2; exit 1; }
fi
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
    echo "The background service cannot read files there. Move the whole directory elsewhere, e.g. ~/Developer/typeless-autosend, then run ./install.sh again." >&2
    exit 1 ;;
esac
if [ ! -d /Applications/Typeless.app ] && [ ! -d "$HOME/Applications/Typeless.app" ]; then
  echo "Warning: Typeless.app not found; continuing anyway (ignore this if it lives elsewhere)"
fi

# Never replace a command owned by another installation or tool.
BIN_DIR="$HOME/.local/bin"
COMMAND_LINK="$BIN_DIR/typeless-autosend"
RELOCATE_LINK=0
if [ -e "$COMMAND_LINK" ] || [ -L "$COMMAND_LINK" ]; then
  if [ ! -L "$COMMAND_LINK" ] || [ "$(readlink "$COMMAND_LINK")" != "$DIR/typeless-autosend" ]; then
    # A dangling link matching our registered LaunchAgent belongs to the moved install.
    registered_binary="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null || true)"
    if [ -L "$COMMAND_LINK" ] && [ ! -e "$COMMAND_LINK" ] &&
       [ -n "$registered_binary" ] && [ "$(readlink "$COMMAND_LINK")" = "$registered_binary" ]; then
      RELOCATE_LINK=1
    else
      echo "Command already exists: $COMMAND_LINK. Remove or relocate it before installing." >&2
      exit 1
    fi
  fi
fi

mkdir -p "$DIR"
cd "$DIR"
# Build into a temp directory first, then replace: no half-written binary is left behind,
# and the code-signing identifier stays typeless-autosend.
mkdir -p .build
if [ -n "$PREBUILT_BINARY" ]; then
  echo "==> Installing precompiled binary"
  cp "$PREBUILT_BINARY" .build/typeless-autosend
else
  echo "==> Building"
  swiftc -O "$SOURCE_DIR"/*.swift -o .build/typeless-autosend -lsqlite3
fi

# Stage first, then stop and verify both service names before replacing the binary.
# bootout can return before launchd has finished removing the job.
stop_service() {
  local label="$1"
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then return; fi
    sleep 0.2
  done
  echo "Service $label could not be stopped; upgrade cancelled. Run: launchctl bootout gui/$UID_NUM/$label" >&2
  exit 1
}
stop_service "$LEGACY_LABEL"
stop_service "$LABEL"
mv .build/typeless-autosend typeless-autosend

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
    cp "$SOURCE_DIR/config.example.json" config.json
  fi
elif [ ${#apps[@]} -gt 0 ]; then
  echo "Note: config.json already exists and was left untouched; --app was ignored. Use typeless-autosend apps add/remove to update it."
fi

rm -f "$LEGACY_PLIST"
if [ -L "$LEGACY_LINK" ] &&
   { [ "$(readlink "$LEGACY_LINK")" = "$DIR/typeless-autoenter" ] ||
     { [ -n "$LEGACY_BINARY" ] && [ "$(readlink "$LEGACY_LINK")" = "$LEGACY_BINARY" ]; }; }; then
  rm "$LEGACY_LINK"
fi
if [ "$REMOVE_LEGACY_BINARY" -eq 1 ]; then rm -f "$DIR/typeless-autoenter"; fi

if [ -n "$PREBUILT_BINARY" ]; then
  cp "$SOURCE_DIR/uninstall.sh" "$DIR/uninstall.sh"
  mkdir -p "$DIR/skill"
  cp "$SOURCE_DIR/skill/SKILL.md" "$DIR/skill/SKILL.md"
  cp "$SOURCE_DIR/BUILD_INFO" "$DIR/BUILD_INFO"
fi

# Request Accessibility once after a (re)install; also clear the legacy input prompt marker.
rm -f .access-prompted .input-monitoring-prompted
# Switch to a fresh log file so the self-check only sees records from this start,
# not the permission state left behind by the previous binary.
if [ -f autosend.log ]; then mv -f autosend.log autosend.log.1; fi

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
        <string>$DIR/typeless-autosend</string>
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
    <string>$DIR/autosend.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/autosend.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

launchctl enable "gui/$UID_NUM/$LABEL" 2>/dev/null || true
loaded=0
err=""
for _ in 1 2 3 4 5; do
  if err="$(launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>&1)"; then loaded=1; break; fi
  sleep 1
done
if [ "$loaded" -ne 1 ]; then
  echo "launchctl bootstrap failed: $err" >&2
  echo "Check: System Settings → General → Login Items & Extensions, and make sure typeless-autosend is not switched off." >&2
  echo "You can also run launchctl print-disabled gui/$UID_NUM | grep typeless to see whether it is disabled." >&2
  exit 1
fi
# Wait for the service to write its start record (up to 10 seconds).
for _ in $(seq 1 20); do
  grep -qs "started," autosend.log && break
  sleep 0.5
done

echo "==> Installing command in $BIN_DIR"
mkdir -p "$BIN_DIR"
if [ "$RELOCATE_LINK" -eq 1 ]; then rm "$COMMAND_LINK"; fi
if [ ! -L "$COMMAND_LINK" ]; then ln -s "$DIR/typeless-autosend" "$COMMAND_LINK"; fi
# Configure only the login user's shell. Never duplicate our marked block.
case "${SHELL:-/bin/zsh}" in
  */zsh) SHELL_PROFILE="${ZDOTDIR:-$HOME}/.zshrc" ;;
  */bash) SHELL_PROFILE="$HOME/.bash_profile" ;;
  *) SHELL_PROFILE="" ;;
esac
# Rename our old markers without changing the user's PATH code or other settings.
if [ -n "$SHELL_PROFILE" ] && grep -Fq '# >>> typeless-autoenter PATH >>>' "$SHELL_PROFILE" 2>/dev/null; then
  sed -i '' 's/# >>> typeless-autoenter PATH >>>/# >>> typeless-autosend PATH >>>/; s/# <<< typeless-autoenter PATH <<</# <<< typeless-autosend PATH <<</' "$SHELL_PROFILE"
fi
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    if [ -n "$SHELL_PROFILE" ]; then
      if ! grep -Fq '# >>> typeless-autosend PATH >>>' "$SHELL_PROFILE" 2>/dev/null; then
        mkdir -p "$(dirname "$SHELL_PROFILE")"
        cat >> "$SHELL_PROFILE" <<'PATH_BLOCK'

# >>> typeless-autosend PATH >>>
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< typeless-autosend PATH <<<
PATH_BLOCK
      fi
      echo "Open a new terminal, or source: $SHELL_PROFILE"
    else
      echo 'Add $HOME/.local/bin to your shell PATH to use the command from any directory.'
    fi
    ;;
esac

# Enable completion in new interactive shells; keep one guarded block per profile.
case "${SHELL:-/bin/zsh}" in
  */zsh|*/bash)
    if ! grep -Fq '# >>> typeless-autosend completion >>>' "$SHELL_PROFILE" 2>/dev/null; then
      mkdir -p "$(dirname "$SHELL_PROFILE")"
      cat >> "$SHELL_PROFILE" <<'COMPLETION_BLOCK'

# >>> typeless-autosend completion >>>
if [[ $- == *i* ]] && command -v typeless-autosend >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(typeless-autosend completion zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(typeless-autosend completion bash)"
  fi
fi
# <<< typeless-autosend completion <<<
COMPLETION_BLOCK
    fi
    echo "Tab completion enabled in new terminals ($SHELL_PROFILE)."
    ;;
  */fish)
    FISH_COMPLETION="${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/typeless-autosend.fish"
    # Do not replace a completion installed by the user or another package.
    if [ ! -e "$FISH_COMPLETION" ] && [ ! -L "$FISH_COMPLETION" ]; then
      mkdir -p "$(dirname "$FISH_COMPLETION")"
      cat > "$FISH_COMPLETION" <<'FISH_BLOCK'
# typeless-autosend managed completion loader
if type -q typeless-autosend
  typeless-autosend completion fish | source
end
FISH_BLOCK
    fi
    echo 'Tab completion is available in new fish sessions; ensure ~/.local/bin is on PATH.'
    ;;
esac

echo "==> Self-check"
doctor_status=0
doctor_output="$(./typeless-autosend doctor)" || doctor_status=$?
printf '%s\n' "$doctor_output"

# Doctor can fail for unrelated reasons (database, config, Secure Input, etc.).
# Only its explicit permission failures call for opening Accessibility settings.
if [ "$doctor_status" -ne 0 ] && printf '%s\n' "$doctor_output" | grep -Eq '^  ✗ Background service (lacks Accessibility permission:|Input Monitoring is unavailable \(listen_permission_denied\))'; then
  echo "==> Opening privacy settings"
  if ! open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' 2>/dev/null; then
    echo "Could not open Accessibility settings. Use the manual path below." >&2
  fi

  cat <<EOF

Required permission is missing. Opening this page does not grant permission.

Permission setup:
     In System Settings → Privacy & Security → Accessibility:
  1. Remove the existing typeless-autosend entry with − (skip if there is no entry).
  2. Click + and add the current executable:
     $DIR/typeless-autosend
  3. Turn on its Accessibility switch.
  4. Restart the service and verify permission:
     launchctl kickstart -k gui/$UID_NUM/$LABEL
     typeless-autosend doctor
     All good means setup is complete.
EOF
elif [ "$doctor_status" -ne 0 ]; then
  echo "Resolve the self-check issues above, then run: typeless-autosend doctor"
fi

cat <<EOF

Useful commands:
  1. Find installed applications: typeless-autosend apps search <name>
     Enable one by Bundle ID: typeless-autosend apps add <bundle.id>
  2. Configure the delay: typeless-autosend delay set 1
     Pause/resume: typeless-autosend service pause / service resume
  3. Check: typeless-autosend service status / doctor. Log: $DIR/autosend.log
EOF
