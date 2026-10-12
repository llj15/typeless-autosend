# typeless-autoenter

Typeless 转写完成、文字粘贴进输入框后，自动按一次回车发送。只在你指定的 App 里生效。仅支持 macOS。

## 原理

Typeless 没有官方 hook。每次转写完成，它会往本地 SQLite（`~/Library/Application Support/Typeless/typeless.db`）写一条记录。本程序每 100ms 看一眼这个库：发现新的"已完成"记录，且当前前台 App 在白名单里，就等 150ms，发一次 Return。

## 前置条件

- macOS，已安装 Typeless 并登录
- Xcode Command Line Tools：`xcode-select --install`（安装脚本会在本机编译）
- Typeless 的历史记录保持开启（默认永久保留，`doctor` 会检查）

## 安装

```bash
./install.sh --app com.mitchellh.ghostty    # --app 可重复，首次安装时写入白名单
```

脚本会：编译、生成并加载 LaunchAgent（`local.typeless-autoenter`，开机自启）、创建 `config.json`、运行一次自检。程序、配置和日志都在当前目录，**安装后不要移动目录**；移动了就重新运行 `./install.sh`。

### 授权辅助功能（必须）

发送回车需要辅助功能权限。安装后第一次启动会弹一次授权窗，在 系统设置 → 隐私与安全性 → 辅助功能 里打开 `typeless-autoenter`。

没弹窗，或列表里已有旧条目：先点 `−` 删掉，再点 `+` 添加本目录下的 `typeless-autoenter`。

## 配置 `config.json`

```json
{
  "apps": [
    "com.mitchellh.ghostty",
    "com.tinyspeck.slackmacgap"
  ]
}
```

- `config.json` 是白名单的唯一来源。每次转写完成时现读，改完立即生效，不用重启。
- 查 Bundle ID：先打开目标 App，再运行 `./typeless-autoenter list-apps`。
- 不区分大小写，会去掉首尾空格。
- 文件缺失、格式错误或 `apps` 为空 = 不在任何 App 里回车，原因会写进 `autoenter.log`。
- 不建议加代码编辑器：光标在代码区时，回车只会插入换行。

## 自检

```bash
./typeless-autoenter doctor
```

检查 Typeless、数据库和表结构、历史保留设置、白名单、后台服务的授权状态和运行状态。

## 升级

更新源码后重新运行 `./install.sh`。二进制变了，辅助功能授权会失效，按上面"先删后加"重新授权一次。

## 已知局限

- 回车是在读到记录 150ms 后固定发出的，无法确认 Typeless 的粘贴已经完成。粘贴失败或特别慢时，可能发出一个空回车。
- 依赖 Typeless 的本地数据库结构。Typeless 升级后表结构变了，程序会停止触发，并在日志里写 `db read failing: ...`。
- 每次重新编译，辅助功能授权都要重做。

## 卸载

```bash
./uninstall.sh
```

停止服务并移除 LaunchAgent。目录不会被删除，辅助功能里的条目需要手动删。
