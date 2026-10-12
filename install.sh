#!/bin/bash
# typeless-autoenter 安装：就地编译、生成 LaunchAgent、启动服务。可重复运行，升级也用它。
# 用法：./install.sh [--app <bundle id>]...
#   首次安装时把这些 App 写进 config.json 白名单；config.json 已存在则不改动。
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
      [ $# -ge 2 ] || { echo "--app 需要一个 Bundle ID" >&2; exit 2; }
      echo "$2" | grep -Eq '^[A-Za-z0-9._-]+$' || { echo "Bundle ID 格式不对: $2" >&2; exit 2; }
      apps+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname)" = Darwin ] || { echo "只支持 macOS" >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "没找到编译环境：先运行 xcode-select --install 安装 Command Line Tools，再重新运行本脚本" >&2; exit 1; }
case "$DIR" in
  *[\&\<\>\"]*) echo "目录路径含 & < > \" 字符，换一个目录再安装" >&2; exit 1 ;;
esac
if [ ! -d /Applications/Typeless.app ] && [ ! -d "$HOME/Applications/Typeless.app" ]; then
  echo "警告：没找到 Typeless.app，继续安装（装在别处可以忽略）"
fi

echo "==> 编译"
# 先编到临时目录再替换：不会留下写了一半的二进制，签名标识也保持为 typeless-autoenter
mkdir -p .build
swiftc -O main.swift -o .build/typeless-autoenter -lsqlite3
mv .build/typeless-autoenter typeless-autoenter

if [ ! -f config.json ]; then
  echo "==> 创建 config.json"
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
fi

# 重新安装后第一次启动会弹一次辅助功能授权窗
rm -f .access-prompted

echo "==> 注册并启动服务 ($LABEL)"
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
    <true/>
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
loaded=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then loaded=1; break; fi
  sleep 1
done
[ "$loaded" -eq 1 ] || { echo "launchctl bootstrap 失败：$PLIST" >&2; exit 1; }
sleep 2

echo "==> 自检"
./typeless-autoenter doctor || true

cat <<EOF

接下来：
  1. 辅助功能授权：系统设置 → 隐私与安全性 → 辅助功能，打开 typeless-autoenter。
     没弹窗或列表里已有旧条目（升级后旧条目会失效）：先点 − 删掉，再点 + 添加
     $DIR/typeless-autoenter
  2. 在 $DIR/config.json 的 apps 里填要自动回车的 App；
     运行 ./typeless-autoenter list-apps 可以看到正在运行的 App 的 Bundle ID。
  3. 随时运行 ./typeless-autoenter doctor 检查状态。日志：$DIR/autoenter.log
EOF
