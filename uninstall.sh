#!/bin/bash
# typeless-autoenter uninstaller: stop the service and remove the LaunchAgent. The program directory and config.json are left alone.
set -euo pipefail
LABEL="local.typeless-autoenter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
# Confirm the service is really stopped before deleting the plist; otherwise the process keeps pressing Enter in apps.
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "Warning: the service is still running and could not be stopped; the plist was kept: $PLIST" >&2
  echo "Stop it manually: launchctl bootout gui/$UID_NUM/$LABEL" >&2
  exit 1
fi
rm -f "$PLIST"
DIR="$(cd "$(dirname "$0")" && pwd -P)"
COMMAND_LINK="$HOME/.local/bin/typeless-autoenter"
if [ -L "$COMMAND_LINK" ] && [ "$(readlink "$COMMAND_LINK")" = "$DIR/typeless-autoenter" ]; then
  rm "$COMMAND_LINK"
fi
# Leave the PATH block: ~/.local/bin may also contain other user commands.

echo "Stopped the service and removed $PLIST"
echo "The program directory was not deleted; remove the whole directory if you no longer need it."
echo "The typeless-autoenter entry in the Accessibility list must be removed by hand in System Settings."
