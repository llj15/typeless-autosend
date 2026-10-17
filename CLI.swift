import Foundation
import Darwin

private func cliJSON(_ object: [String: Any], error: Bool = false) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    let handle = error ? FileHandle.standardError : FileHandle.standardOutput
    handle.write(data + Data("\n".utf8))
}

private struct CLIProblem: Error {
    let code: Int32
    let type: String
    let message: String
    let suggestion: String
}

func runCLI(arguments rawArguments: [String], store: SettingsStore, serviceRunning: () -> Bool) -> Int32? {
    guard !rawArguments.isEmpty, rawArguments.first != "doctor", rawArguments.first != "list-apps" else { return nil }
    var arguments = rawArguments
    let dryRun = arguments.contains("--dry-run")
    let ifNotExists = arguments.contains("--if-not-exists")
    let ifExists = arguments.contains("--if-exists")
    let jsonFlag = arguments.contains("--json")
    var format = jsonFlag || isatty(STDOUT_FILENO) == 0 ? "json" : "table"
    if let index = arguments.firstIndex(of: "--format"), index + 1 < arguments.count {
        format = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
    }
    arguments.removeAll { ["--dry-run", "--if-not-exists", "--if-exists", "--json"].contains($0) }
    var appID: String?
    if let index = arguments.firstIndex(of: "--app"), index + 1 < arguments.count {
        appID = normalizeBundleID(arguments[index + 1])
        arguments.removeSubrange(index...index + 1)
    }
    let noun = arguments.first ?? ""
    do {
        guard ["json", "table"].contains(format), !(jsonFlag && format != "json") else {
            throw CLIProblem(code: 2, type: "invalid_arguments", message: "Output format must be json or table; --json requires json", suggestion: "Use --format json or --format table")
        }
        func emit(_ object: [String: Any]) { cliOutput(object, format: dryRun ? "json" : format) }
        if arguments.contains("--help") || arguments.contains("-h") || noun == "help" {
            let path = arguments.filter { $0 != "--help" && $0 != "-h" && $0 != "help" }
            let text = try cliHelp(path: path)
            FileHandle.standardOutput.write(Data(text.utf8))
            return 0
        }
        let command = Array(arguments.prefix(2))
        var allowedFlags: Set<String> = ["--json", "--format"]
        if [["apps", "add"], ["apps", "remove"], ["delay", "set"], ["delay", "reset"], ["service", "pause"], ["service", "resume"]].contains(command) { allowedFlags.insert("--dry-run") }
        if command == ["apps", "add"] { allowedFlags.insert("--if-not-exists") }
        if command == ["apps", "remove"] { allowedFlags.insert("--if-exists") }
        if noun == "delay" { allowedFlags.insert("--app") }
        if noun == "schema" { allowedFlags.insert("--all") }
        var flags = Set<String>()
        for flag in rawArguments where flag.hasPrefix("--") {
            guard allowedFlags.contains(flag), flags.insert(flag).inserted else {
                throw CLIProblem(code: 2, type: "invalid_arguments", message: "Unsupported or repeated option \(flag)", suggestion: "Run typeless-autosend --help for supported options")
            }
        }
        func validateBundleID(_ id: String) throws {
            guard id.range(of: "^[a-z0-9-]+(?:\\.[a-z0-9-]+)+$", options: .regularExpression) != nil else {
                throw CLIProblem(code: 2, type: "invalid_arguments", message: "Invalid Bundle ID: \(id)", suggestion: "Find an ID with typeless-autosend apps search <name>")
            }
        }
        if let id = appID { try validateBundleID(id) }
        if noun == "apps", ["add", "remove"].contains(arguments.dropFirst().first ?? ""), arguments.count == 3 { try validateBundleID(normalizeBundleID(arguments[2])) }
        if noun == "schema" {
            let path = Array(arguments.dropFirst())
            if path.isEmpty || path == ["--all"] {
                cliJSON(["schemaVersion": 1, "commands": cliCommandSchemas(), "exitCodes": cliExitCodes])
                return 0
            }
            if let schema = cliCommandSchemas().first(where: { $0["name"] as? String == path.joined(separator: " ") }) {
                cliJSON(schema)
                return 0
            }
            throw CLIProblem(code: 2, type: "invalid_arguments", message: "Unknown schema command: \(path.joined(separator: " "))", suggestion: "Run typeless-autosend schema --all")
        }
        if noun == "apps", arguments.count >= 2, arguments[1] == "search", arguments.count <= 3 {
            let settings = try store.read()
            let apps = installedApplications(matching: arguments.count == 3 ? arguments[2] : "").map { metadata -> [String: Any] in
                var app = metadata
                let id = app["bundleID"] as? String ?? ""
                app["enabled"] = settings.apps.contains(where: { normalizeBundleID($0) == id })
                return app
            }
            emit(["apps": apps, "count": apps.count])
            return 0
        }
        if arguments.count == 2, noun == "service", ["pause", "resume", "status"].contains(arguments[1]) {
            let settings: AutosendSettings
            if arguments[1] == "status" { settings = try store.read() }
            else {
                settings = try store.update(dryRun: dryRun) {
                    let wasPaused = $0.paused
                    $0.paused = arguments[1] == "pause"
                    if $0.paused { $0.cancellationRevision = try nextCancellationRevision($0.cancellationRevision) }
                    else if wasPaused { $0.resumeAfter = Date().timeIntervalSince1970 }
                }
            }
            let runtime = currentRuntimeStatus(store: store)
            emit(["running": serviceRunning() || runtime != nil, "paused": settings.paused, "delaySeconds": settings.delaySeconds,
                  "apps": settings.apps, "configPath": store.path, "lastSkipReason": runtime?["lastSkipReason"] ?? NSNull(),
                  "pending": runtime?["pending"] ?? false, "inputMonitoringAvailable": runtime?["inputMonitoringAvailable"] ?? NSNull(),
                  "pid": runtime?["pid"] ?? NSNull(), "updatedAt": runtime?["updatedAt"] ?? NSNull(), "dryRun": dryRun])
            return dryRun ? 10 : 0
        }
        if arguments == ["delay", "get"] {
            let settings = try store.read()
            emit(delayResult(settings, appID: appID))
            return 0
        }
        if arguments.count == 3, noun == "delay", arguments[1] == "set" {
            guard let seconds = Double(arguments[2]), seconds.isFinite, seconds >= 0, seconds <= maximumDelaySeconds else {
                throw CLIProblem(code: 2, type: "invalid_arguments", message: "Delay must be finite and in scheduler range 0...\(maximumDelaySeconds) seconds", suggestion: "Use a nonnegative delay such as typeless-autosend delay set 1")
            }
            let settings = try store.update(dryRun: dryRun) {
                if let id = appID { $0.appDelaySeconds[id] = seconds }
                else { $0.delaySeconds = seconds }
            }
            var result = delayResult(settings, appID: appID)
            result["dryRun"] = dryRun
            emit(result)
            return dryRun ? 10 : 0
        }
        if arguments == ["delay", "reset"] {
            let settings = try store.update(dryRun: dryRun) {
                if let id = appID { $0.appDelaySeconds.removeValue(forKey: id) }
                else { $0.delaySeconds = 1 }
            }
            var result = delayResult(settings, appID: appID)
            result["dryRun"] = dryRun
            emit(result)
            return dryRun ? 10 : 0
        }
        if arguments.count == 3, noun == "apps", arguments[1] == "add" {
            let id = normalizeBundleID(arguments[2])
            var changed = false
            let result = try store.update(dryRun: dryRun) { settings in
                if settings.apps.contains(where: { normalizeBundleID($0) == id }) {
                    if !ifNotExists { throw CLIProblem(code: 5, type: "already_exists", message: "App \(id) is already enabled", suggestion: "Use apps add \(id) --if-not-exists") }
                } else { settings.apps.append(id); changed = true }
            }
            emit(["bundleID": id, "enabled": result.apps.contains(where: { normalizeBundleID($0) == id }), "dryRun": dryRun, "changed": changed])
            return dryRun ? 10 : 0
        }
        if arguments == ["apps", "list"] {
            let settings = try store.read()
            let apps = settings.apps.map { id -> [String: Any] in
                var app = applicationMetadata(bundleID: normalizeBundleID(id))
                app["enabled"] = true
                return app
            }
            emit(["apps": apps, "count": apps.count])
            return 0
        }
        if arguments.count == 3, noun == "apps", arguments[1] == "remove" {
            let id = normalizeBundleID(arguments[2])
            var changed = false
            _ = try store.update(dryRun: dryRun) { settings in
                changed = settings.apps.contains(where: { normalizeBundleID($0) == id })
                if !changed && !ifExists { throw CLIProblem(code: 3, type: "not_found", message: "App \(id) is not enabled", suggestion: "Use apps remove \(id) --if-exists") }
                settings.apps.removeAll { normalizeBundleID($0) == id }
                settings.appDelaySeconds.removeValue(forKey: id)
                if changed { settings.appCancellationRevisions[id] = try nextCancellationRevision(settings.appCancellationRevisions[id] ?? 0) }
            }
            emit(["bundleID": id, "enabled": false, "dryRun": dryRun, "changed": changed])
            return dryRun ? 10 : 0
        }
        throw CLIProblem(code: 2, type: "invalid_arguments", message: "Unknown command or invalid arguments", suggestion: "Run typeless-autosend --help")
    } catch let error as CLIProblem {
        cliJSON(["error": error.type, "message": error.message, "suggestion": error.suggestion, "retryable": false, "input": rawArguments], error: true)
        return error.code
    } catch {
        cliJSON(["error": "configuration_error", "message": error.localizedDescription, "suggestion": "Check the config.json file at \(store.path)", "retryable": false, "input": rawArguments], error: true)
        return 1
    }
}

private func nextCancellationRevision(_ current: UInt64) throws -> UInt64 {
    let (next, overflow) = current.addingReportingOverflow(1)
    guard !overflow else {
        throw CLIProblem(code: 1, type: "configuration_error", message: "Cancellation revision exhausted its supported range", suggestion: "Stop the service and restore a valid configuration before retrying")
    }
    return next
}

private func currentRuntimeStatus(store: SettingsStore) -> [String: Any]? {
    let url = URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("runtime-status.json")
    guard let data = try? Data(contentsOf: url),
          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let number = state["pid"] as? NSNumber, number.int32Value > 0,
          let updated = state["updatedAt"] as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: updated) ?? ISO8601DateFormatter().date(from: updated),
          abs(Date().timeIntervalSince(date)) < 10 else { return nil }
    guard kill(number.int32Value, 0) == 0 || errno == EPERM else { return nil }
    return state
}

private let cliExitCodes = ["0": "success", "1": "configuration or I/O error", "2": "invalid arguments", "3": "not found", "4": "permission denied", "5": "already exists", "10": "dry-run preview succeeded"]

private func cliCommandSchemas() -> [[String: Any]] {
    let common: [[String: Any]] = [
        ["name": "--json", "type": "boolean", "required": false, "default": false, "description": "Use JSON output"],
        ["name": "--format", "type": "string", "required": false, "enum": ["json", "table"], "default": "table for TTY, json otherwise"],
        ["name": "--help", "type": "boolean", "required": false, "default": false, "description": "Show command help"]
    ]
    let dry: [String: Any] = ["name": "--dry-run", "type": "boolean", "required": false, "default": false, "description": "Preview JSON without writing; exit 10"]
    let app: [String: Any] = ["name": "--app", "type": "string", "required": false, "description": "Bundle ID for an app-specific delay"]
    let entries: [(String, String, [[String: Any]], [[String: Any]], String)] = [
        ("apps add", "Enable automatic Enter for a Bundle ID immediately", [["name": "bundle-id", "type": "string", "required": true]], [dry, ["name": "--if-not-exists", "type": "boolean", "required": false, "default": false]], "apps add com.apple.TextEdit --if-not-exists"),
        ("apps remove", "Remove an app and its delay override", [["name": "bundle-id", "type": "string", "required": true]], [dry, ["name": "--if-exists", "type": "boolean", "required": false, "default": false]], "apps remove com.apple.TextEdit --if-exists"),
        ("apps list", "List enabled apps with installed and running metadata", [], [], "apps list --json"),
        ("apps search", "Search all installed apps by name or Bundle ID; no query lists all", [["name": "query", "type": "string", "required": false]], [], "apps search TextEdit"),
        ("delay get", "Read global or effective app delay in seconds", [], [app], "delay get --app com.apple.TextEdit"),
        ("delay set", "Set delay within the supported scheduler range; fractional seconds allowed", [["name": "seconds", "type": "number", "required": true, "minimum": 0, "maximum": maximumDelaySeconds]], [app, dry], "delay set 0.5 --app com.apple.TextEdit"),
        ("delay reset", "Restore global delay to 1 second or remove an app override", [], [app, dry], "delay reset --app com.apple.TextEdit"),
        ("service pause", "Persistently pause automatic Enter", [], [dry], "service pause"),
        ("service resume", "Persistently resume automatic Enter", [], [dry], "service resume"),
        ("service status", "Read service state, pause state and last skip reason", [], [], "service status --json"),
        ("doctor", "Run legacy installation and permission checks", [], [], "doctor"),
        ("list-apps", "List running apps (legacy command)", [], [["name": "--all", "type": "boolean", "required": false, "default": false]], "list-apps --all")
    ]
    return entries.map { name, description, arguments, flags, example in
        ["name": name, "description": description, "arguments": arguments, "flags": (["doctor", "list-apps"].contains(name) ? [] : common) + flags, "examples": ["typeless-autosend " + example]]
    }
}

private func cliHelp(path: [String]) throws -> String {
    let target = path.joined(separator: " ")
    let schemas = cliCommandSchemas().filter {
        let name = $0["name"] as? String ?? ""
        return target.isEmpty || name == target || name.hasPrefix(target + " ")
    }
    guard !schemas.isEmpty else {
        throw CLIProblem(code: 2, type: "invalid_arguments", message: "Unknown help command: \(target)", suggestion: "Run typeless-autosend --help")
    }
    var lines = ["Examples:", "  typeless-autosend apps search TextEdit", "  typeless-autosend apps add com.apple.TextEdit", "  typeless-autosend delay set 0.5", "", "Usage: typeless-autosend " + (target.isEmpty ? "<resource> <action>" : target), ""]
    for schema in schemas {
        lines.append("  \(schema["name"] as? String ?? ""): \(schema["description"] as? String ?? "")")
    }
    lines += ["", "Options: --json | --format json|table (optional; TTY: table, pipe: json)", "         --help, -h; help <resource> <action>"]
    if schemas.count == 1 {
        for argument in schemas[0]["arguments"] as? [[String: Any]] ?? [] {
            lines.append("Argument: \(argument["name"] as? String ?? "") (\((argument["required"] as? Bool ?? false) ? "required" : "optional"))")
        }
        let flags = schemas[0]["flags"] as? [[String: Any]] ?? []
        let names = flags.compactMap { $0["name"] as? String }.filter { !["--json", "--format", "--help"].contains($0) }
        if !names.isEmpty { lines.append("Optional flags: " + names.joined(separator: ", ")) }
    }
    lines += ["", "Schema: typeless-autosend schema --all | schema <resource> <action>", "Exit codes: 0 success; 1 config/I/O; 2 usage; 3 not found; 4 permission; 5 exists; 10 dry-run", ""]
    return lines.joined(separator: "\n")
}

private func cliOutput(_ object: [String: Any], format: String) {
    guard format == "table" else { cliJSON(object); return }
    var lines: [String] = []
    if let apps = object["apps"] as? [[String: Any]] {
        lines.append("BUNDLE ID\tNAME\tRUNNING\tENABLED")
        for app in apps {
            lines.append(["bundleID", "name", "running", "enabled"].map { cliTableValue(app[$0]) }.joined(separator: "\t"))
        }
        lines.append("\(apps.count) app(s)")
    } else {
        lines.append("FIELD\tVALUE")
        for key in object.keys.sorted() { lines.append("\(key)\t\(cliTableValue(object[key]))") }
    }
    FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}

private func cliTableValue(_ value: Any?) -> String {
    guard let value = value, !(value is NSNull) else { return "-" }
    if let value = value as? String { return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) { return text }
    return String(describing: value)
}

private func delayResult(_ settings: AutosendSettings, appID: String?) -> [String: Any] {
    ["scope": appID == nil ? "global" : "app", "bundleID": appID as Any? ?? NSNull(),
     "delaySeconds": appID.map { settings.effectiveDelay(for: $0) } ?? settings.delaySeconds,
     "globalDelaySeconds": settings.delaySeconds,
     "overrideSeconds": appID.flatMap { settings.appDelaySeconds[$0] } as Any? ?? NSNull()]
}
