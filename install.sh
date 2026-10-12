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
swiftc --version >/dev/null 2>&1 || {
  echo "swiftc 不可用：先运行 xcode-select --install 安装 Command Line Tools。" >&2
  echo "已经装过的话：试试 sudo xcodebuild -license accept，或更新 Command Line Tools，再重新运行本脚本。" >&2
  exit 1
}
case "$DIR" in
  *[\&\<\>\"]*) echo "目录路径含 & < > \" 字符，换一个目录再安装" >&2; exit 1 ;;
esac
# 后台服务读不了 macOS 受保护目录里的文件（读不到 config.json 就等于没开任何 App）
case "$DIR" in
  "$HOME/Desktop"|"$HOME/Desktop/"*|"$HOME/Documents"|"$HOME/Documents/"*|"$HOME/Downloads"|"$HOME/Downloads/"*|"$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*)
    echo "当前目录在 macOS 受保护位置（桌面 / 文档 / 下载 / iCloud）：$DIR" >&2
    echo "后台服务读不到这里的文件。请把整个目录移到别处，例如 ~/Developer/typeless-autoenter，再运行 ./install.sh" >&2
    exit 1 ;;
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
elif [ ${#apps[@]} -gt 0 ]; then
  echo "提示：config.json 已存在，没有改动，--app 参数被忽略；请直接编辑 config.json"
fi

# 重新安装后第一次启动会弹一次辅助功能授权窗
rm -f .access-prompted
# 日志换新文件，自检只会读到这次启动的记录，不会读到旧二进制留下的授权状态
if [ -f autoenter.log ]; then mv -f autoenter.log autoenter.log.1; fi

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
  echo "launchctl bootstrap 失败：$err" >&2
  echo "检查：系统设置 → 通用 → 登录项与扩展 里是否关掉了 typeless-autoenter；" >&2
  echo "也可以运行 launchctl print-disabled gui/$UID_NUM | grep typeless 看是否被禁用。" >&2
  exit 1
fi
# 等服务写出启动记录（最多 10 秒）
for _ in $(seq 1 20); do
  grep -qs "started," autoenter.log && break
  sleep 0.5
done

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
