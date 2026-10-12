// typeless-autoenter: Typeless 转写完成并粘贴后，若前台 App 在 config.json 白名单里，自动按一次回车。
// 信号来源：Typeless 的 typeless.db 中 history_v2 出现新的 completed 记录。
//
//   typeless-autoenter            作为后台服务运行（由 install.sh 注册为 LaunchAgent）
//   typeless-autoenter doctor     自检：Typeless、数据库、配置、授权、服务
//   typeless-autoenter list-apps  列出正在运行的 App 的 Bundle ID，用来填 config.json
import AppKit
import ApplicationServices
import Foundation
import SQLite3

let env = ProcessInfo.processInfo.environment
// 程序所在目录：config.json、日志、授权标记都放这里（install.sh 就地编译，移动目录后需重新运行 install.sh）
let programDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath().deletingLastPathComponent().path
let dbPath = env["TYPELESS_DB"] ?? NSHomeDirectory() + "/Library/Application Support/Typeless/typeless.db"
// 生效 App 白名单放在配置文件里，每次触发时现读，改完无需重启、重新编译或重新授权
let configPath = env["TYPELESS_AUTOENTER_CONFIG"] ?? programDir + "/config.json"
let logPath = programDir + "/autoenter.log"
let promptMarkerPath = programDir + "/.access-prompted"
let serviceLabel = "local.typeless-autoenter"
// dry run：不检查真实前台、不真正按键，只打日志（测试用）
let dryRun = env["TYPELESS_DRY_RUN"] == "1"
let pasteModes: Set<String> = ["voice_transcript", "voice_translation"]
let requiredColumns: Set<String> = ["id", "mode", "status", "refined_text", "updated_at"]
let pollInterval: TimeInterval = 0.1
let enterDelay: TimeInterval = Double(env["TYPELESS_ENTER_DELAY"] ?? "") ?? 0.15
// 只看最近 N 条本地记录（rowid 单调递增），不依赖 created_at，长录音也能命中
let recentRowCount = 20
// updated_at 与当前时间相差超过该值视为旧记录，防止迟到的触发
let freshnessSeconds: TimeInterval = 10
// 读库连续失败这么多次才记日志，避免 Typeless 短暂持锁时刷屏；之后降频重试
let persistentFailureCount = 20

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func log(_ msg: String) {
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    print("[\(ts)] \(msg)")
    fflush(stdout)
}

struct Row { let id: String; let mode: String; let textLen: Int; let updatedAt: Date? }
struct FetchError: Error { let message: String }

func columnString(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
    sqlite3_column_text(stmt, i).map { String(cString: $0) }
}

func sqliteMessage(_ db: OpaquePointer?) -> String {
    db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
}

func tableColumns(_ db: OpaquePointer?) -> Set<String>? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(history_v2)", -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    var columns = Set<String>()
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return columns }
        guard rc == SQLITE_ROW else { return nil }
        if let name = columnString(stmt, 1) { columns.insert(name) }
    }
}

// 失败（锁冲突、表结构不兼容、文件缺失等）带原因返回，调用方下一轮重试
func fetchRecentCompleted() -> Result<[Row], FetchError> {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let msg = sqliteMessage(db)
        sqlite3_close(db)
        return .failure(FetchError(message: "cannot open \(dbPath): \(msg)"))
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)

    guard let columns = tableColumns(db) else {
        return .failure(FetchError(message: "cannot read schema: \(sqliteMessage(db))"))
    }
    if columns.isEmpty {
        return .failure(FetchError(message: "table history_v2 not found (incompatible Typeless version?)"))
    }
    let missing = requiredColumns.subtracting(columns)
    guard missing.isEmpty else {
        return .failure(FetchError(message: "history_v2 missing columns: \(missing.sorted().joined(separator: ", ")) (incompatible Typeless version?)"))
    }

    // 云端同步/回填写入的行（synced_from_cloud=1）不是本机听写，不能占「最近 N 条」的名额；老版本没有这一列就不过滤
    let local = columns.contains("synced_from_cloud") ? "synced_from_cloud = 0" : "1"
    let sql = """
        SELECT id, mode, length(coalesce(refined_text, '')), updated_at FROM history_v2
        WHERE rowid > (SELECT coalesce(max(rowid), 0) FROM history_v2 WHERE \(local)) - \(recentRowCount)
          AND status = 'completed' AND \(local)
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return .failure(FetchError(message: "query failed: \(sqliteMessage(db))"))
    }
    defer { sqlite3_finalize(stmt) }

    var rows: [Row] = []
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return .success(rows) }
        guard rc == SQLITE_ROW else {
            return .failure(FetchError(message: "read failed: \(sqliteMessage(db))"))
        }
        guard let id = columnString(stmt, 0) else { continue }
        let updated = columnString(stmt, 3).flatMap { isoFrac.date(from: $0) ?? isoPlain.date(from: $0) }
        rows.append(Row(id: id, mode: columnString(stmt, 1) ?? "",
                        textLen: Int(sqlite3_column_int(stmt, 2)), updatedAt: updated))
    }
}

struct FileSig: Equatable { let mtime: Date?; let size: Int? }

func fileSig(_ path: String) -> FileSig {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return FileSig(mtime: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.intValue)
}

// 同时盯主库和 -wal：Typeless 若换成 WAL 模式，写入先落在 -wal 里，主库 mtime 要等 checkpoint 才变
func dbSignature() -> [FileSig] { [fileSig(dbPath), fileSig(dbPath + "-wal")] }

struct Config: Decodable { let apps: [String] }
enum ConfigError: Error { case missing, invalid }

func readConfig() -> Result<[String], ConfigError> {
    guard let data = FileManager.default.contents(atPath: configPath) else { return .failure(.missing) }
    guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return .failure(.invalid) }
    return .success(config.apps)
}

// 文件缺失或格式错误时回退到空白名单（全部不回车），宁可不发也不在别的 App 里乱回车
func loadTargetBundleIDs() -> Set<String> {
    switch readConfig() {
    case .success(let apps):
        // Bundle ID 手写容易大小写、空格出错，统一规整后再比较
        return Set(apps.map(normalizeBundleID))
    case .failure(.missing):
        log("config missing, no apps enabled: \(configPath)")
        return []
    case .failure(.invalid):
        log("config invalid, no apps enabled: \(configPath)")
        return []
    }
}

func normalizeBundleID(_ id: String) -> String {
    id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func frontmostIsTarget() -> (Bool, String) {
    let front: String
    if dryRun {
        // dry run 下可用 TYPELESS_FAKE_FRONT 模拟前台 App，不设则恒通过
        guard let fake = env["TYPELESS_FAKE_FRONT"] else { return (true, "dry-run") }
        front = fake
    } else {
        front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    }
    return (loadTargetBundleIDs().contains(normalizeBundleID(front)), front)
}

func accessibilityTrusted(prompt: Bool = false) -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
}

func pressEnter() {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: down) else { continue }
        // 清掉残留的 Fn 等修饰键标志，否则 fn+Return 会变成小键盘 Enter
        ev.flags = []
        ev.post(tap: .cghidEventTap)
    }
}

// MARK: - 子命令

func listApps() {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? "?", $0) } }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    for (name, id) in apps { print("\(id)\t\(name)") }
}

func launchctlOutput(_ args: [String]) -> (status: Int32, output: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func runDoctor() -> Int32 {
    var failures = 0
    func ok(_ msg: String) { print("  ✓ \(msg)") }
    func warn(_ msg: String) { print("  ! \(msg)") }
    func fail(_ msg: String) { print("  ✗ \(msg)"); failures += 1 }

    print("typeless-autoenter doctor (\(programDir))")

    let appPaths = ["/Applications/Typeless.app", NSHomeDirectory() + "/Applications/Typeless.app"]
    if appPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
        ok("已安装 Typeless")
    } else {
        warn("没找到 Typeless.app（装在别处可以忽略）")
    }

    switch fetchRecentCompleted() {
    case .success(let rows): ok("数据库可读，表结构兼容（最近 \(rows.count) 条已完成记录）")
    case .failure(let error): fail("数据库不可用：\(error.message)")
    }

    let settingsURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("app-settings.json")
    if let data = try? Data(contentsOf: settingsURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let seconds = json["historyDurationSeconds"] as? Int {
        if seconds == -1 {
            ok("Typeless 历史记录永久保留")
        } else {
            warn("Typeless 历史只保留 \(seconds) 秒：记录可能在被检测到之前就被清理，建议在 Typeless 设置里改成永久")
        }
    } else {
        warn("读不到 Typeless 的历史保留设置，已跳过")
    }

    switch readConfig() {
    case .failure(.missing):
        fail("配置文件不存在：\(configPath)")
    case .failure(.invalid):
        fail("配置文件格式错误，需要 {\"apps\": [\"bundle.id\", ...]}：\(configPath)")
    case .success(let apps):
        if apps.isEmpty {
            fail("config.json 的 apps 为空，不会在任何 App 里回车；运行 list-apps 查 Bundle ID")
        }
        for id in apps {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                warn("\(id)：没找到对应的已安装 App，检查拼写")
            } else {
                ok("白名单：\(id)")
            }
        }
    }

    // 看服务自己记录的授权状态：从终端运行 doctor 时，权限是算在终端头上的，不能代表后台服务
    if let text = try? String(contentsOfFile: logPath, encoding: .utf8),
       let line = text.split(separator: "\n").last(where: { $0.contains("accessibility trusted=") }) {
        if line.contains("accessibility trusted=true") {
            ok("后台服务已获得辅助功能权限")
        } else {
            fail("后台服务没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能；列表里若已有 typeless-autoenter 先点 − 删掉，再用 + 添加 \(programDir)/typeless-autoenter")
        }
    } else {
        warn("日志里还没有服务的授权记录（服务没启动过？）")
    }

    if let result = launchctlOutput(["print", "gui/\(getuid())/\(serviceLabel)"]),
       result.status == 0, result.output.contains("state = running") {
        ok("后台服务在运行")
    } else {
        fail("后台服务没在运行：重新运行 install.sh")
    }

    print(failures == 0 ? "一切正常" : "有 \(failures) 项需要处理")
    return failures == 0 ? 0 : 1
}

let subcommand = CommandLine.arguments.dropFirst().first
if subcommand == "list-apps" { listApps(); exit(0) }
if subcommand == "doctor" { exit(runDoctor()) }
if let unknown = subcommand {
    FileHandle.standardError.write(Data("unknown command: \(unknown)\nusage: typeless-autoenter [doctor|list-apps]\n".utf8))
    exit(2)
}

// MARK: - 后台服务

var lastTrusted = true
if dryRun {
    log("started (dry run), db=\(dbPath)")
} else {
    lastTrusted = accessibilityTrusted()
    if !lastTrusted && !FileManager.default.fileExists(atPath: promptMarkerPath) {
        // 每次安装后的第一次启动弹一次授权窗；之后服务重启不再弹，避免反复打扰
        FileManager.default.createFile(atPath: promptMarkerPath, contents: nil)
        _ = accessibilityTrusted(prompt: true)
    }
    log("started, accessibility trusted=\(lastTrusted), enterDelay=\(enterDelay)s, config=\(configPath)")
}

// 首次成功读库后才建立基线，基线内的记录不触发
var seen: Set<String>?
var lastSig: [FileSig] = []
var failures = 0
var tick = 0
// 已有一次回车在排队时，同一时间窗里的其它记录并入它，不连发
var enterPending = false

func process(_ rows: [Row]) {
    guard var known = seen else {
        seen = Set(rows.map(\.id))
        log("baseline ready, \(rows.count) recent completed rows")
        return
    }
    defer { seen = known }

    for row in rows where !known.contains(row.id) {
        known.insert(row.id)
        let age = row.updatedAt.map { Date().timeIntervalSince($0) }
        let ageText = age.map { String(format: "%.1fs", $0) } ?? "?"
        let fresh = age.map { abs($0) < freshnessSeconds } ?? false
        // 先判断便宜的条件，通过了才去读配置和前台
        guard pasteModes.contains(row.mode), row.textLen > 0, fresh else {
            log("skip id=\(row.id) mode=\(row.mode) len=\(row.textLen) age=\(ageText)")
            continue
        }
        let (isTarget, front) = frontmostIsTarget()
        guard isTarget else {
            log("skip id=\(row.id) front=\(front) not in whitelist")
            continue
        }
        guard !enterPending else {
            log("skip id=\(row.id) coalesced into pending enter")
            continue
        }
        enterPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDelay) {
            defer { enterPending = false }
            let (stillTarget, frontNow) = frontmostIsTarget()
            guard stillTarget else {
                log("skip id=\(row.id) front changed to \(frontNow)")
                return
            }
            if dryRun {
                log("would enter id=\(row.id) mode=\(row.mode) len=\(row.textLen)")
                return
            }
            guard AXIsProcessTrusted() else {
                log("skip id=\(row.id) accessibility not trusted")
                return
            }
            pressEnter()
            log("enter id=\(row.id) mode=\(row.mode) len=\(row.textLen)")
        }
    }
}

let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
    tick += 1
    // 每 5 秒看一次授权状态，变化时记一行（doctor 靠这行判断后台服务有没有权限）
    if !dryRun && tick % 50 == 0 {
        let trusted = accessibilityTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            log("accessibility trusted=\(trusted) (changed)")
        }
    }
    // 持续失败后降频到每秒一次，避免每 100ms 反复打开数据库、等锁
    if failures >= persistentFailureCount && tick % 10 != 0 { return }

    let sig = dbSignature()
    guard seen == nil || sig != lastSig else { return }
    switch fetchRecentCompleted() {
    case .failure(let error):
        failures += 1
        if failures == persistentFailureCount { log("db read failing: \(error.message)") }
    case .success(let rows):
        if failures >= persistentFailureCount { log("db read recovered") }
        failures = 0
        lastSig = sig
        process(rows)
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
