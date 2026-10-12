#!/bin/bash
# typeless-autoenter 卸载：停止服务并移除 LaunchAgent。程序目录和 config.json 不动。
set -euo pipefail
LABEL="local.typeless-autoenter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
# 确认服务真的停了再删 plist，否则进程会继续在 App 里发回车
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "警告：服务仍在运行，没能停掉，plist 保留未删：$PLIST" >&2
  echo "手动停止：launchctl bootout gui/$UID_NUM/$LABEL" >&2
  exit 1
fi
rm -f "$PLIST"

echo "已停止服务并移除 $PLIST"
echo "程序目录没有删除，不需要了可以直接删掉整个目录。"
echo "辅助功能列表里的 typeless-autoenter 条目需要在系统设置里手动删除。"
