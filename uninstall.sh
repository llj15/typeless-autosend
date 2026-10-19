#!/bin/bash
# Typeless AutoSend uninstaller: stop both service names and remove owned command links and configuration.
set -euo pipefail
UID_NUM="$(id -u)"
DIR="$(cd "$(dirname "$0")" && pwd -P)"
for LABEL in local.typeless-autosend local.typeless-autoenter; do
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  # Keep registration and command links if stopping failed; never hide a live job.
  if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "Warning: the service is still running and could not be stopped; the plist was kept: $PLIST" >&2
    echo "Stop it manually: launchctl bootout gui/$UID_NUM/$LABEL" >&2
    exit 1
  fi
  rm -f "$PLIST"
done
for COMMAND in typeless-autosend typeless-autoenter; do
  COMMAND_LINK="$HOME/.local/bin/$COMMAND"
  if [ -L "$COMMAND_LINK" ] && [ "$(readlink "$COMMAND_LINK")" = "$DIR/$COMMAND" ]; then
    rm "$COMMAND_LINK"
  fi
done
rm -f "$DIR/config.json"
# Leave the PATH block: ~/.local/bin may also contain other user commands.
echo "Stopped the service and removed its LaunchAgents"
echo "Removed configuration: $DIR/config.json"
echo "The program directory was not deleted; remove the whole directory if you no longer need it."
echo "The Typeless AutoSend entry (and any older typeless-autoenter entry) in Accessibility and Input Monitoring must be removed by hand in System Settings."
