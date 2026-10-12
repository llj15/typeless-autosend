#!/bin/bash
# typeless-autoenter 卸载：停止服务并移除 LaunchAgent。程序目录和 config.json 不动。
set -euo pipefail
LABEL="local.typeless-autoenter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "已停止服务并移除 $PLIST"
echo "程序目录没有删除，不需要了可以直接删掉整个目录。"
echo "辅助功能列表里的 typeless-autoenter 条目需要在系统设置里手动删除。"
