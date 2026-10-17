import Foundation
import Darwin

// Dispatch deadlines use signed 64-bit nanoseconds. Leave one second of
// headroom for conversion rounding at the largest representable interval.
let maximumDelaySeconds = Double(Int64.max) / 1_000_000_000 - 1

func normalizeBundleID(_ id: String) -> String {
    id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

struct AutosendSettings: Codable {
    var apps: [String] = []
    var delaySeconds: Double = 1
    var appDelaySeconds: [String: Double] = [:]
    var paused: Bool = false
    var resumeAfter: Double = 0
    var cancellationRevision: UInt64 = 0
    var appCancellationRevisions: [String: UInt64] = [:]
    // SettingsStore carries unknown values as JSON bytes so future numeric
    // fields are never converted through a narrower Swift number type.
    fileprivate var unknownFields: [String: Data] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: SettingsCodingKey.self)
        apps = try values.decode([String].self, forKey: .init("apps"))
        delaySeconds = try values.decodeIfPresent(Double.self, forKey: .init("delaySeconds")) ?? 1
        appDelaySeconds = try values.decodeIfPresent([String: Double].self, forKey: .init("appDelaySeconds")) ?? [:]
        paused = try values.decodeIfPresent(Bool.self, forKey: .init("paused")) ?? false
        resumeAfter = try values.decodeIfPresent(Double.self, forKey: .init("resumeAfter")) ?? 0
        guard resumeAfter.isFinite, resumeAfter >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .init("resumeAfter"), in: values, debugDescription: "resumeAfter must be a finite nonnegative timestamp")
        }
        cancellationRevision = try values.decodeIfPresent(UInt64.self, forKey: .init("cancellationRevision")) ?? 0
        let revisions = try values.decodeIfPresent([String: UInt64].self, forKey: .init("appCancellationRevisions")) ?? [:]
        for key in revisions.keys.sorted() { appCancellationRevisions[normalizeBundleID(key)] = revisions[key] }
        guard delaySeconds.isFinite, delaySeconds >= 0, delaySeconds <= maximumDelaySeconds else {
            throw DecodingError.dataCorruptedError(forKey: .init("delaySeconds"), in: values, debugDescription: "delaySeconds is outside the supported scheduler range 0...\(maximumDelaySeconds)")
        }
        var overrides: [String: Double] = [:]
        for key in appDelaySeconds.keys.sorted() {
            guard let seconds = appDelaySeconds[key], seconds.isFinite, seconds >= 0, seconds <= maximumDelaySeconds else {
                throw DecodingError.dataCorruptedError(forKey: .init("appDelaySeconds"), in: values, debugDescription: "Every app delay must be in the supported scheduler range 0...\(maximumDelaySeconds)")
            }
            overrides[normalizeBundleID(key)] = appDelaySeconds[key]
        }
        appDelaySeconds = overrides
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: SettingsCodingKey.self)
        try values.encode(apps, forKey: .init("apps"))
        try values.encode(delaySeconds, forKey: .init("delaySeconds"))
        try values.encode(appDelaySeconds, forKey: .init("appDelaySeconds"))
        try values.encode(paused, forKey: .init("paused"))
        try values.encode(resumeAfter, forKey: .init("resumeAfter"))
        try values.encode(cancellationRevision, forKey: .init("cancellationRevision"))
        try values.encode(appCancellationRevisions, forKey: .init("appCancellationRevisions"))
    }

    func effectiveDelay(for bundleID: String) -> Double {
        appDelaySeconds[normalizeBundleID(bundleID)] ?? delaySeconds
    }
}

private struct SettingsCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private let knownSettingsKeys: Set<String> = ["apps", "delaySeconds", "appDelaySeconds", "paused", "resumeAfter", "cancellationRevision", "appCancellationRevisions"]

// Preserve JSONDecoder's supported Unicode encodings while giving the raw
// value scanner a single byte encoding. Transcoding leaves numeric text intact.
private func utf8SettingsData(_ data: Data) throws -> Data {
    let prefix = Array(data.prefix(4))
    var encoding = String.Encoding.utf8
    var bomLength = 0
    if prefix.starts(with: [0, 0, 254, 255]) { encoding = .utf32BigEndian; bomLength = 4 }
    else if prefix.starts(with: [255, 254, 0, 0]) { encoding = .utf32LittleEndian; bomLength = 4 }
    else if prefix.starts(with: [239, 187, 191]) { bomLength = 3 }
    else if prefix.starts(with: [254, 255]) { encoding = .utf16BigEndian; bomLength = 2 }
    else if prefix.starts(with: [255, 254]) { encoding = .utf16LittleEndian; bomLength = 2 }
    else if prefix.count == 4 {
        if prefix[0] == 0 && prefix[1] == 0 && prefix[2] == 0 { encoding = .utf32BigEndian }
        else if prefix[1] == 0 && prefix[2] == 0 && prefix[3] == 0 { encoding = .utf32LittleEndian }
        else if prefix[0] == 0 && prefix[2] == 0 { encoding = .utf16BigEndian }
        else if prefix[1] == 0 && prefix[3] == 0 { encoding = .utf16LittleEndian }
    }
    let payload = Data(data.dropFirst(bomLength))
    if encoding == .utf8 { return payload }
    guard let text = String(data: payload, encoding: encoding) else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Configuration has invalid Unicode encoding"))
    }
    return Data(text.utf8)
}

// JSONDecoder validates the entire document before this scanner runs. Here we
// only find top-level value boundaries, respecting strings and nested values.
private func unknownSettingsFields(in data: Data) throws -> [String: Data] {
    let bytes = Array(data)
    var index = 0
    func skipWhitespace() {
        while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }
    func stringEnd() {
        index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2 }
            else if bytes[index] == 34 { index += 1; return }
            else { index += 1 }
        }
    }
    skipWhitespace()
    index += 1 // opening object brace, already checked by JSONDecoder
    var fields: [String: Data] = [:]
    while index < bytes.count {
        skipWhitespace()
        if index >= bytes.count || bytes[index] == 125 { break }
        let keyStart = index
        stringEnd()
        let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<index]))
        skipWhitespace()
        index += 1 // colon
        skipWhitespace()
        let valueStart = index
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 { stringEnd(); continue }
            if byte == 91 || byte == 123 { depth += 1 }
            else if byte == 93 || byte == 125 {
                if depth == 0 { break }
                depth -= 1
            } else if byte == 44 && depth == 0 { break }
            index += 1
        }
        if !knownSettingsKeys.contains(key) { fields[key] = Data(bytes[valueStart..<index]) }
        if index < bytes.count && bytes[index] == 44 { index += 1 }
        else { break }
    }
    return fields
}

struct SettingsStore {
    let path: String

    func read() throws -> AutosendSettings {
        guard FileManager.default.fileExists(atPath: path) else { return AutosendSettings() }
        let data = try utf8SettingsData(Data(contentsOf: URL(fileURLWithPath: path)))
        var settings = try JSONDecoder().decode(AutosendSettings.self, from: data)
        settings.unknownFields = try unknownSettingsFields(in: data)
        return settings
    }

    func update(dryRun: Bool = false, _ mutate: (inout AutosendSettings) throws -> Void) throws -> AutosendSettings {
        if dryRun {
            var settings = try read()
            try mutate(&settings)
            return settings
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(fd, LOCK_UN) }
        var settings = try read()
        try mutate(&settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(settings)
        data.removeLast() // closing brace
        while let last = data.last, [UInt8(32), 9, 10, 13].contains(last) { data.removeLast() }
        for key in settings.unknownFields.keys.sorted() {
            data.append(Data(",\n  ".utf8))
            data.append(try encoder.encode(key))
            data.append(Data(": ".utf8))
            data.append(settings.unknownFields[key]!)
        }
        data.append(Data("\n}\n".utf8))
        try data.write(to: url, options: .atomic)
        return settings
    }
}
