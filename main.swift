// typeless-autosend: after Typeless finishes a transcription and pastes it, press Return once
// if the frontmost app is on the config.json whitelist.
// Signal source: a new completed record appearing in history_v2 of Typeless's typeless.db.
//
//   typeless-autosend            run as the background service (registered as a LaunchAgent by install.sh)
//   typeless-autosend doctor     self-check: Typeless, database, config, permission, service
//   typeless-autosend list-apps  list the Bundle IDs of running apps, for filling in config.json
import AppKit
import ApplicationServices
import Foundation
import SQLite3

let env = ProcessInfo.processInfo.environment
// Program directory: config.json, the log and the permission-prompt marker live here
// (install.sh builds in place; re-run install.sh after moving the directory).
let programDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath().deletingLastPathComponent().path
let dbPath = env["TYPELESS_DB"] ?? NSHomeDirectory() + "/Library/Application Support/Typeless/typeless.db"
// The app whitelist lives in the config file and is re-read on every trigger,
// so edits need no restart, rebuild or re-authorization.
// Prefer the new override while accepting existing scripts during migration.
let configPath = env["TYPELESS_AUTOSEND_CONFIG"] ?? env["TYPELESS_AUTOENTER_CONFIG"] ?? programDir + "/config.json"
let logPath = programDir + "/autosend.log"
let promptMarkerPath = programDir + "/.access-prompted"
let serviceLabel = "local.typeless-autosend"
// Dry run: skip the real frontmost-app check and never press a key, only log (for tests).
let dryRun = env["TYPELESS_DRY_RUN"] == "1"
let pasteModes: Set<String> = ["voice_transcript", "voice_translation"]
let requiredColumns: Set<String> = ["id", "mode", "status", "refined_text", "updated_at"]
let pollInterval: TimeInterval = 0.1
let enterDelay: TimeInterval = 0.15
// Only look at the most recent N local records (rowid is monotonic), independent of created_at,
// so long recordings are still caught.
let recentRowCount = 20
// A record whose updated_at differs from the current time by more than this is treated as old,
// so late triggers are ignored.
let freshnessSeconds: TimeInterval = 10
// Log a database read failure only after this many consecutive failures, so a brief lock held
// by Typeless does not flood the log; after that, retry less often.
let persistentFailureCount = 20
// How long a new instance waits for the single-instance lock before concluding that another one is really running.
let lockWait: TimeInterval = Double(env["TYPELESS_LOCK_WAIT"] ?? "") ?? 5
let lockRetryInterval: TimeInterval = 0.25

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

struct Row {
    let sequence: Int64
    let id: String
    let mode: String
    let status: String?
    let refinedText: String
    let textLen: Int
    let updatedAt: Date?
}
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

// Failures (lock contention, incompatible schema, missing file, ...) are returned with a reason;
// the caller retries on the next tick.
func fetchRecentLocalRows() -> Result<[Row], FetchError> {
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

    // Rows written by cloud sync / backfill (synced_from_cloud=1) are not local dictations and must not
    // take up slots in the "most recent N" window; older versions without this column are not filtered.
    let local = columns.contains("synced_from_cloud") ? "synced_from_cloud = 0" : "1"
    let sql = """
        SELECT rowid, id, mode, status, coalesce(refined_text, ''), length(coalesce(refined_text, '')), updated_at
        FROM history_v2 WHERE \(local)
        ORDER BY rowid DESC LIMIT \(recentRowCount)
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        return .failure(FetchError(message: "query failed: \(sqliteMessage(db))"))
    }
    defer { sqlite3_finalize(stmt) }

    var rows: [Row] = []
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return .success(rows.reversed()) }
        guard rc == SQLITE_ROW else {
            return .failure(FetchError(message: "read failed: \(sqliteMessage(db))"))
        }
        guard let id = columnString(stmt, 1) else { continue }
        let updated = columnString(stmt, 6).flatMap { isoFrac.date(from: $0) ?? isoPlain.date(from: $0) }
        rows.append(Row(sequence: sqlite3_column_int64(stmt, 0), id: id,
                        mode: columnString(stmt, 2) ?? "", status: columnString(stmt, 3),
                        refinedText: columnString(stmt, 4) ?? "",
                        textLen: Int(sqlite3_column_int(stmt, 5)), updatedAt: updated))
    }
}

// The event thread can send before the next database poll. Recheck the local row
// boundary at that final authorization point too. A locked/unreadable database
// denies the send without waiting on Typeless while an input event is blocked.
func noNewerLocalDictation(after sequence: Int64) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return false
    }
    defer { sqlite3_close(db) }
    guard let columns = tableColumns(db), requiredColumns.isSubset(of: columns) else { return false }
    let local = columns.contains("synced_from_cloud") ? "synced_from_cloud = 0" : "1"
    var stmt: OpaquePointer?
    let sql = "SELECT EXISTS(SELECT 1 FROM history_v2 WHERE rowid > ? AND \(local))"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_bind_int64(stmt, 1, sequence) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return false }
    return sqlite3_column_int(stmt, 0) == 0
}

// Bind a captured paste only after the latest local dictation is completed.
// A late paste from an older transcript must not acquire the ID of a newer
// recording whose placeholder is still incomplete; cloud history is excluded.
func latestLocalRecordID() -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    guard let columns = tableColumns(db), requiredColumns.isSubset(of: columns) else { return nil }
    let local = columns.contains("synced_from_cloud") ? "synced_from_cloud = 0" : "1"
    var stmt: OpaquePointer?
    let sql = "SELECT id, status FROM history_v2 WHERE \(local) ORDER BY rowid DESC LIMIT 1"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, columnString(stmt, 1) == "completed" else { return nil }
    return columnString(stmt, 0)
}

struct FileSig: Equatable { let mtime: Date?; let size: Int? }

func fileSig(_ path: String) -> FileSig {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return FileSig(mtime: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.intValue)
}

// Watch both the main database and its -wal file: if Typeless switches to WAL mode, writes land
// in the -wal first and the main file's mtime only changes on checkpoint.
func dbSignature() -> [FileSig] { [fileSig(dbPath), fileSig(dbPath + "-wal")] }

enum ConfigError: Error { case missing, invalid }

func readConfig() -> Result<AutosendSettings, ConfigError> {
    guard FileManager.default.fileExists(atPath: configPath) else { return .failure(.missing) }
    guard let config = try? SettingsStore(path: configPath).read() else { return .failure(.invalid) }
    return .success(config)
}

// A missing or invalid config falls back to an empty whitelist (never press Enter):
// better to send nothing than to press Enter in the wrong app.
func loadTargetBundleIDs() -> Set<String> {
    var result = readConfig()
    // An editor with non-atomic writes can leave a half-written file; read once more after a short
    // pause so that is not mistaken for a broken config.
    if case .failure(.invalid) = result {
        Thread.sleep(forTimeInterval: 0.05)
        result = readConfig()
    }
    switch result {
    case .success(let settings):
        let apps = settings.apps
        if apps.isEmpty { log("config has no apps, nothing enabled: \(configPath)") }
        // Hand-written Bundle IDs are easy to get wrong in case or whitespace; normalize before comparing.
        return Set(apps.map(normalizeBundleID))
    case .failure(.missing):
        log("config missing, no apps enabled: \(configPath)")
        return []
    case .failure(.invalid):
        log("config invalid, no apps enabled: \(configPath)")
        return []
    }
}

func frontmostIsTarget() -> (Bool, String) {
    let front: String
    if dryRun {
        // In dry run, TYPELESS_FAKE_FRONT simulates the frontmost app; if unset the check always passes.
        front = env["TYPELESS_FAKE_FRONT"] ?? "dry-run"
    } else {
        front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    }
    return (loadTargetBundleIDs().contains(normalizeBundleID(front)), front)
}

func accessibilityTrusted(prompt: Bool = false) -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
}

// MARK: - Subcommands

// includeAccessory: also list menu-bar and launcher apps (Raycast, Alfred, ...).
func listApps(includeAccessory: Bool) {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular || (includeAccessory && $0.activationPolicy == .accessory) }
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

    print("typeless-autosend doctor (\(programDir))")

    let appPaths = ["/Applications/Typeless.app", NSHomeDirectory() + "/Applications/Typeless.app"]
    if appPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
        ok("Typeless is installed")
    } else {
        warn("Typeless.app not found (ignore this if it lives elsewhere)")
    }

    switch fetchRecentLocalRows() {
    case .success(let rows): ok("Database readable, schema compatible (\(rows.filter { $0.status == "completed" }.count) recent completed records)")
    case .failure(let error): fail("Database unavailable: \(error.message)")
    }

    let settingsURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("app-settings.json")
    if let data = try? Data(contentsOf: settingsURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let seconds = json["historyDurationSeconds"] as? Int {
        if seconds == -1 {
            ok("Typeless keeps its history forever")
        } else {
            warn("Typeless keeps its history for only \(seconds) seconds: records may be purged before they are detected; set it to forever in Typeless settings")
        }
    } else {
        warn("Cannot read Typeless's history retention setting, skipped")
    }

    switch readConfig() {
    case .failure(.missing):
        fail("Config file not found: \(configPath)")
    case .failure(.invalid):
        fail("Config file is invalid, expected {\"apps\": [\"bundle.id\", ...]}: \(configPath)")
    case .success(let settings):
        let apps = settings.apps
        if apps.isEmpty {
            fail("config.json has no apps, so Enter is never sent; run list-apps to find Bundle IDs")
        }
        for id in apps {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                warn("\(id): no installed app found for this Bundle ID, check the spelling")
            } else {
                ok("Whitelisted: \(id)")
            }
        }
    }

    // Report the permission state recorded by the service itself: when doctor runs from a terminal,
    // the permission counts against the terminal and says nothing about the background service.
    if let text = try? String(contentsOfFile: logPath, encoding: .utf8),
       let line = text.split(separator: "\n").last(where: { $0.contains("accessibility trusted=") }) {
        if line.contains("accessibility trusted=true") {
            ok("Background service has Accessibility permission")
        } else {
            fail("Background service lacks Accessibility permission: System Settings → Privacy & Security → Accessibility. If typeless-autosend is already listed, remove it with − first, then add \(programDir)/typeless-autosend with +")
        }
    } else {
        warn("No Accessibility record from the service in the log yet (has it ever started?)")
    }

    if let runtime = currentRuntimeStatus(store: SettingsStore(path: configPath)) {
        if runtime["inputMonitoringAvailable"] as? Bool == true {
            ok("Background service Input Monitoring is available")
        } else {
            let reason = runtime["inputMonitoringReason"] as? String ?? "unavailable"
            let suggestion: String
            switch reason {
            case "secure_input": suggestion = "Finish secure input (for example, leave the password field), then retry."
            case "listen_permission_denied": suggestion = "Check System Settings → Privacy & Security → Accessibility; after granting permission, restart the service with: launchctl kickstart -k gui/\(getuid())/\(serviceLabel)"
            default: suggestion = "The service retries listener recovery once per second. If it remains unavailable, restart it with: launchctl kickstart -k gui/\(getuid())/\(serviceLabel)"
            }
            fail("Background service Input Monitoring is unavailable (\(reason)). \(suggestion)")
        }
    } else {
        fail("No current Input Monitoring status from the service. Run typeless-autosend service status; restart with: launchctl kickstart -k gui/\(getuid())/\(serviceLabel)")
    }

    if let result = launchctlOutput(["print", "gui/\(getuid())/\(serviceLabel)"]),
       result.status == 0, result.output.contains("state = running") {
        ok("Background service is running")
    } else {
        fail("Background service is not running: re-run install.sh")
    }

    print(failures == 0 ? "All good" : "\(failures) issue(s) to fix")
    return failures == 0 ? 0 : 1
}

let subcommand = CommandLine.arguments.dropFirst().first
if let result = runCLI(arguments: Array(CommandLine.arguments.dropFirst()), store: SettingsStore(path: configPath), serviceRunning: {
    guard let result = launchctlOutput(["print", "gui/\(getuid())/\(serviceLabel)"]) else { return false }
    return result.status == 0 && result.output.contains("state = running")
}) { exit(result) }
if subcommand == "list-apps" { listApps(includeAccessory: CommandLine.arguments.contains("--all")); exit(0) }
if subcommand == "doctor" { exit(runDoctor()) }
if let unknown = subcommand {
    FileHandle.standardError.write(Data("unknown command: \(unknown)\nusage: typeless-autosend [doctor|list-apps [--all]]\n".utf8))
    exit(2)
}

// MARK: - Background service

// Single instance: a second instance in the same directory (run by hand, or a leftover from a restart race)
// would press Enter several times per transcription. If another instance still holds the lock after the wait,
// exit with status 0 so launchd does not restart it. The wait covers the old instance that is still shutting
// down, e.g. right after install.sh's bootout.
let lockPath = programDir + "/.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 {
    log("warning: cannot create lock file \(lockPath), single-instance protection off")
} else {
    let lockDeadline = Date().addingTimeInterval(lockWait)
    while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        if errno == EINTR { continue }
        // Only EWOULDBLOCK means someone else holds the lock; any other failure must not kill the service.
        guard errno == EWOULDBLOCK else {
            log("warning: cannot lock \(lockPath) (errno \(errno)), single-instance protection off")
            break
        }
        if Date() >= lockDeadline {
            log("another instance is already running, exiting (lock: \(lockPath))")
            exit(0)
        }
        Thread.sleep(forTimeInterval: lockRetryInterval)
    }
}

var lastTrusted = true
if dryRun {
    log("started (dry run), db=\(dbPath)")
} else {
    lastTrusted = accessibilityTrusted()
    if !lastTrusted && !FileManager.default.fileExists(atPath: promptMarkerPath) {
        // Show the authorization prompt once, on the first start after each install; later service
        // restarts do not prompt again, to avoid nagging.
        FileManager.default.createFile(atPath: promptMarkerPath, contents: nil)
        _ = accessibilityTrusted(prompt: true)
    }
    log("started, accessibility trusted=\(lastTrusted), enterDelay=\(enterDelay)s, config=\(configPath)")
}

// The baseline is built after the first successful database read; records in it never trigger.
var seen: Set<String>?
var lastSig: [FileSig] = []
var failures = 0
var tick = 0
// While one Enter is already queued, other records in the same window fold into it instead of firing again.
var enterPending = false
var pendingGeneration = 0
var pendingRowID: String?
var pendingSequence: Int64?
var awaitingPasteRetry = false
var pendingFocus: FocusSnapshot?
var pendingCancellationRevisions: (global: UInt64, app: UInt64)?
let inputMonitor = InputMonitor(dryRun: dryRun, environment: env)
inputMonitor.pasteRecordIDProvider = latestLocalRecordID
var lastSkipReason: String?
let runtimeStatusPath = URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("runtime-status.json")

func writeRuntimeStatus() {
    var status: [String: Any] = ["pid": getpid(), "updatedAt": isoFrac.string(from: Date()),
        "pending": enterPending, "inputMonitoringAvailable": inputMonitor.available]
    status.merge(inputMonitor.monitoringDetails) { _, new in new }
    status["lastSkipReason"] = lastSkipReason ?? NSNull()
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
        try? data.write(to: runtimeStatusPath, options: .atomic)
    }
}

func recordSkip(_ id: String, _ reason: String) {
    lastSkipReason = reason
    log("skip id=\(id) \(reason)")
    writeRuntimeStatus()
}

func clearPendingState() {
    pendingGeneration += 1
    enterPending = false
    pendingRowID = nil
    pendingSequence = nil
    pendingFocus = nil
    pendingCancellationRevisions = nil
}

func finishPendingSend() {
    guard enterPending, let id = pendingRowID else { return }
    let outcome = inputMonitor.endAttemptOutcome()
    clearPendingState()
    if let reason = outcome.sentReason { log("\(dryRun ? "would enter" : "enter") id=\(id) destination=\(reason)") }
    else { recordSkip(id, outcome.cancellationReason ?? "attempt cancelled before send reporting") }
    writeRuntimeStatus()
}

func cancelPending(_ reason: String) {
    guard enterPending, let id = pendingRowID else { return }
    // Atomically disarm or consume the send result. The event thread cannot
    // deliver an old timer between our decision and cancellation.
    let outcome = inputMonitor.endAttemptOutcome()
    clearPendingState()
    if let sentReason = outcome.sentReason {
        log("\(dryRun ? "would enter" : "enter") id=\(id) destination=\(sentReason)")
        writeRuntimeStatus()
    } else { recordSkip(id, outcome.cancellationReason ?? reason) }
}
inputMonitor.onKeyboard = cancelPending
inputMonitor.onFocusChange = cancelPending
inputMonitor.onMonitoringChange = { log($0) }
inputMonitor.onSent = { _ in finishPendingSend() }

func cancelSupersededPending(_ rows: [Row]) {
    if let pending = pendingSequence, let latest = rows.max(by: { $0.sequence < $1.sequence }),
       latest.sequence > pending {
        cancelPending("superseded by newer local dictation")
    }
}

func process(_ rows: [Row]) {
    guard var known = seen else {
        let completed = rows.filter { $0.status == "completed" }
        seen = Set(completed.map(\.id))
        log("baseline ready, \(completed.count) recent completed rows")
        return
    }
    defer { seen = known }
    awaitingPasteRetry = false
    let newest = rows.max { $0.sequence < $1.sequence }
    cancelSupersededPending(rows)

    for row in rows where row.status == "completed" && !known.contains(row.id) {
        let age = row.updatedAt.map { Date().timeIntervalSince($0) }
        let ageText = age.map { String(format: "%.1fs", $0) } ?? "?"
        let fresh = age.map { abs($0) < freshnessSeconds } ?? false
        let settingsResult = readConfig()
        if case .success(let settings) = settingsResult, settings.paused {
            known.insert(row.id)
            recordSkip(row.id, "autosend paused")
            continue
        }
        if case .success(let settings) = settingsResult, settings.resumeAfter > 0,
           let completedAt = row.updatedAt, completedAt.timeIntervalSince1970 <= settings.resumeAfter {
            known.insert(row.id)
            recordSkip(row.id, "completed at or before latest resume")
            continue
        }
        if let recoveredAfter = inputMonitor.recoveredAfter, let completedAt = row.updatedAt,
           completedAt <= recoveredAfter {
            known.insert(row.id)
            recordSkip(row.id, "completed at or before input monitoring recovery")
            continue
        }
        // A newer local row means another dictation has already started, even if
        // its status is NULL. Never arm an older completion from this snapshot.
        if let latest = newest, row.sequence < latest.sequence {
            known.insert(row.id)
            let reason = latest.status == "completed"
                ? "coalesced into newer completed transcript"
                : "superseded by newer local dictation"
            recordSkip(row.id, reason)
            continue
        }
        // A record whose status turned completed before its text was written: while it is fresh, do not
        // consume it yet and wait for the text (a genuinely empty record is skipped as old once it goes stale).
        if fresh && row.textLen == 0 && pasteModes.contains(row.mode) { continue }
        known.insert(row.id)
        // Check the cheap conditions first; only then read the config and the frontmost app.
        guard pasteModes.contains(row.mode), row.textLen > 0, fresh else {
            recordSkip(row.id, "mode=\(row.mode) len=\(row.textLen) age=\(ageText)")
            continue
        }
        let settings: AutosendSettings
        switch settingsResult {
        case .success(let value): settings = value
        case .failure(.missing): recordSkip(row.id, "config missing, no apps enabled"); continue
        case .failure(.invalid): recordSkip(row.id, "config invalid, no apps enabled"); continue
        }
        if settings.apps.isEmpty { log("config has no apps, nothing enabled: \(configPath)") }
        if enterPending {
            cancelPending("superseded by newer local dictation")
        }
        let focus: FocusSnapshot
        switch inputMonitor.beginAttempt(recordID: row.id) {
        case .failure(let error):
            if error.reason == "awaiting Typeless paste" {
                known.remove(row.id)
                awaitingPasteRetry = true
            } else { recordSkip(row.id, error.reason) }
            continue
        case .success(let snapshot): focus = snapshot
        }
        // beginAttempt can recover a listener after a slow database read has
        // crossed the retry deadline, so use the latest recovery boundary too.
        if let recoveredAfter = inputMonitor.recoveredAfter, let completedAt = row.updatedAt,
           completedAt <= recoveredAfter {
            recordSkip(row.id, "completed at or before input monitoring recovery")
            continue
        }
        let front = focus.bundleID
        let isTarget = Set(settings.apps.map(normalizeBundleID)).contains(normalizeBundleID(front))
        guard isTarget else {
            recordSkip(row.id, "front=\(front) not in whitelist")
            continue
        }
        let additionalDelay = settings.effectiveDelay(for: front)
        guard additionalDelay.isFinite, additionalDelay >= 0,
              additionalDelay <= maximumDelaySeconds else {
            recordSkip(row.id, "configured delay exceeds scheduler range")
            continue
        }
        enterPending = true
        pendingRowID = row.id
        pendingSequence = row.sequence
        pendingFocus = focus
        let cancellationRevision = settings.cancellationRevision
        let appCancellationRevision = settings.appCancellationRevisions[normalizeBundleID(front)] ?? 0
        pendingCancellationRevisions = (cancellationRevision, appCancellationRevision)
        inputMonitor.armAttempt(focus: focus, pastedText: row.refinedText, authorize: {
            guard case .success(let latest) = readConfig(), !latest.paused,
                  Set(latest.apps.map(normalizeBundleID)).contains(normalizeBundleID(front)),
                  latest.cancellationRevision == cancellationRevision,
                  (latest.appCancellationRevisions[normalizeBundleID(front)] ?? 0) == appCancellationRevision else { return false }
            return noNewerLocalDictation(after: row.sequence)
        })
        pendingGeneration += 1
        let generation = pendingGeneration
        writeRuntimeStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDelay) {
            guard generation == pendingGeneration, enterPending else { return }
            inputMonitor.settleAttempt()
        }
        func deliverWhenSafe() {
            inputMonitor.poll()
            guard generation == pendingGeneration, enterPending else { return }
            // A focus-event send may have consumed the attempt on the event thread
            // while this main-loop callback was waiting for the lock.
            if inputMonitor.sentAwaitingReport { return }
            inputMonitor.deliver { sent in
                guard generation == pendingGeneration, enterPending else { return }
                if inputMonitor.sentAwaitingReport { finishPendingSend(); return }
                guard sent else {
                    cancelPending("original input changed, unavailable or sending no longer authorized")
                    return
                }
                finishPendingSend()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDelay + additionalDelay, execute: deliverWhenSafe)
    }
}

func pollDatabase() -> [Row]? {
    // After persistent failures, drop to one retry per second instead of reopening the database
    // and waiting on its lock every 100ms.
    if failures >= persistentFailureCount && tick % 10 != 0 { return nil }

    let sig = dbSignature()
    guard seen == nil || awaitingPasteRetry || sig != lastSig else { return nil }
    switch fetchRecentLocalRows() {
    case .failure(let error):
        failures += 1
        if failures == persistentFailureCount { log("db read failing: \(error.message)") }
        return nil
    case .success(let rows):
        if failures >= persistentFailureCount { log("db read recovered") }
        failures = 0
        lastSig = sig
        return rows
    }
}

let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
    tick += 1
    // Cancel old work before queued departure events can send it. Apply current
    // input/permission events before binding any newly completed transcript.
    let rows = pollDatabase()
    if let rows { cancelSupersededPending(rows) }
    inputMonitor.poll()
    if let rows { process(rows) }
    if enterPending, inputMonitor.sentAwaitingReport { finishPendingSend() }
    if enterPending, !inputMonitor.available { cancelPending("input monitoring unavailable") }
    if enterPending, let focus = pendingFocus {
        if !inputMonitor.sentAwaitingReport, case .failure(let error) = inputMonitor.validateAttempt() {
            cancelPending(error.reason)
        }
        if case .success(let settings) = readConfig() {
            if settings.paused { cancelPending("autosend paused") }
            else if let revisions = pendingCancellationRevisions,
                    settings.cancellationRevision != revisions.global {
                cancelPending("pause was requested during countdown")
            }
            else if let revisions = pendingCancellationRevisions,
                    (settings.appCancellationRevisions[normalizeBundleID(focus.bundleID)] ?? 0) != revisions.app {
                cancelPending("app was removed during countdown")
            }
            else if !Set(settings.apps.map(normalizeBundleID)).contains(normalizeBundleID(focus.bundleID)) {
                cancelPending("app removed from whitelist")
            }
        } else { cancelPending("config unavailable") }
    }
    if tick % 10 == 1 { writeRuntimeStatus() }
    // Check the permission state every 5 seconds and log a line when it changes
    // (doctor relies on this line to tell whether the background service has permission).
    if !dryRun && tick % 50 == 0 {
        let trusted = accessibilityTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            log("accessibility trusted=\(trusted) (changed)")
        }
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
