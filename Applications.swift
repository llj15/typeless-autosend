import AppKit

func installedApplications(matching query: String) -> [[String: Any]] {
    var urls = Set<URL>()
    // Spotlight also finds applications outside the usual Applications folders.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["-0", "kMDItemContentTypeTree == 'com.apple.application-bundle'"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    if (try? process.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for path in data.split(separator: 0) {
            if let value = String(data: path, encoding: .utf8) { urls.insert(URL(fileURLWithPath: value)) }
        }
    }
    // Indexing may be off or incomplete, especially for the built-in system apps.
    let roots = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Library/CoreServices"]
    for root in roots {
        guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
            urls.insert(url)
            entries.skipDescendants()
        }
    }
    for app in NSWorkspace.shared.runningApplications {
        if let url = app.bundleURL { urls.insert(url) }
    }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.map(normalizeBundleID) })
    var apps: [String: [String: Any]] = [:]
    for url in urls.sorted(by: { $0.path < $1.path }) {
        guard let bundle = Bundle(url: url), let rawID = bundle.bundleIdentifier else { continue }
        let id = normalizeBundleID(rawID)
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard needle.isEmpty || id.contains(needle) || name.lowercased().contains(needle) else { continue }
        if apps[id] == nil {
            apps[id] = ["bundleID": id, "name": name, "running": running.contains(id), "installed": true, "path": url.path]
        }
    }
    return apps.values.sorted {
        let left = $0["name"] as? String ?? ""
        let right = $1["name"] as? String ?? ""
        if left == right { return ($0["bundleID"] as? String ?? "") < ($1["bundleID"] as? String ?? "") }
        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }
}

func applicationMetadata(bundleID: String) -> [String: Any] {
    let running = NSWorkspace.shared.runningApplications.first {
        normalizeBundleID($0.bundleIdentifier ?? "") == bundleID
    }
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    let name = running?.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? bundleID
    return ["bundleID": bundleID, "name": name, "running": running != nil, "installed": url != nil, "path": url?.path as Any? ?? NSNull()]
}
