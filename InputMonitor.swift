import AppKit
import ApplicationServices
import Carbon
import Foundation

struct FocusSnapshot {
    var bundleID: String
    var processID: pid_t = 0
    var window: AXUIElement?
    var input: AXUIElement?
    var windowToken = "window-1"
    var inputToken = "input-1"
    var selectionStart = 0
    var selectionLength = 0

    func sameTarget(as other: FocusSnapshot) -> Bool {
        guard normalizeBundleID(bundleID) == normalizeBundleID(other.bundleID), processID == other.processID,
              windowToken == other.windowToken, inputToken == other.inputToken else { return false }
        if let window, let otherWindow = other.window, !CFEqual(window, otherWindow) { return false }
        if let input, let otherInput = other.input, !CFEqual(input, otherInput) { return false }
        return (window == nil) == (other.window == nil) && (input == nil) == (other.input == nil)
    }

    func sameSelection(as other: FocusSnapshot) -> Bool {
        sameTarget(as: other) && selectionStart == other.selectionStart && selectionLength == other.selectionLength
    }
}

struct InputMonitorError: Error { let reason: String }

private struct InputMonitoringState: Equatable {
    var permissionGranted = true
    var secureInputEnabled = false
    var tapPresent = true
    var tapValid = true
    var sourcePresent = true
    var tapEnabled = true

    var unavailableReason: String? {
        if !permissionGranted { return "listen_permission_denied" }
        if secureInputEnabled { return "secure_input" }
        if !tapPresent { return "tap_missing" }
        if !tapValid { return "tap_invalid" }
        if !sourcePresent { return "tap_source_missing" }
        if !tapEnabled { return "tap_disabled" }
        return nil
    }
}

private func validSelectionRange(location: Int, length: Int) -> Bool {
    location >= 0 && length >= 0 && location != NSNotFound && length != NSNotFound
}

// The only simulated system boundary is enabled by TYPELESS_DRY_RUN. It never posts keys.
final class InputMonitor {
    let dryRun: Bool
    private let eventPath: String?
    private var eventOffset = 0
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var focusObserver: AXObserver?
    private var simulatedFocus: FocusSnapshot
    private var focusReadable = true
    private var simulatedMonitoring = InputMonitoringState()
    private var simulatedEnableSucceeds = true
    private var simulatedCreateSucceeds = true
    private var attemptEpoch = 0
    private var attemptActive = false
    private var armedFocus: FocusSnapshot?
    private var mouseSelectionBaseline: FocusSnapshot?
    private(set) var mouseChecksPending = 0
    private var nextRecoveryAt: TimeInterval = 0
    private var lastReportedMonitoringState: InputMonitoringState?
    private var observedMonitoringGap = false
    private(set) var recoveredAfter: Date?
    private(set) var recoveryAttempts = 0
    private var monitoringState: InputMonitoringState {
        let state: InputMonitoringState
        if dryRun { state = simulatedMonitoring }
        else {
            state = InputMonitoringState(permissionGranted: CGPreflightListenEventAccess(),
                secureInputEnabled: IsSecureEventInputEnabled(), tapPresent: tap != nil,
                tapValid: tap.map { CFMachPortIsValid($0) } ?? false,
                sourcePresent: tapSource.map { CFRunLoopSourceIsValid($0) && CFRunLoopContainsSource(CFRunLoopGetMain(), $0, .commonModes) } ?? false,
                tapEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)
        }
        // Even a health-only check before sending must remember an observed
        // gap if the OS recovers before the next recovery poll.
        if state.unavailableReason != nil { observedMonitoringGap = true }
        return state
    }
    var available: Bool { monitoringState.unavailableReason == nil }
    var monitoringDetails: [String: Any] {
        let state = monitoringState
        return ["inputMonitoringAvailable": state.unavailableReason == nil,
            "inputMonitoringReason": state.unavailableReason as Any? ?? NSNull(),
            "inputMonitoringPermissionGranted": state.permissionGranted,
            "secureInputEnabled": state.secureInputEnabled, "inputTapPresent": state.tapPresent,
            "inputTapValid": state.tapValid, "inputTapSourcePresent": state.sourcePresent,
            "inputTapEnabled": state.tapEnabled, "inputMonitoringRecoveryAttempts": recoveryAttempts,
            "inputMonitoringRecoveredAt": recoveredAfter.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) } as Any? ?? NSNull()]
    }
    var onKeyboard: ((String) -> Void)?
    var onFocusChange: ((String) -> Void)?
    var onMonitoringChange: ((String) -> Void)?

    init(dryRun: Bool, environment: [String: String]) {
        self.dryRun = dryRun
        eventPath = dryRun ? environment["TYPELESS_TEST_EVENTS"] : nil
        simulatedFocus = FocusSnapshot(bundleID: environment["TYPELESS_FAKE_FRONT"] ?? "dry-run")
        if !dryRun {
            installTap()
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.onFocusChange?("frontmost application changed")
            }
        }
    }

    private func installTap() {
        if dryRun {
            guard simulatedCreateSucceeds else { return }
            simulatedMonitoring.tapPresent = true
            simulatedMonitoring.tapValid = true
            simulatedMonitoring.sourcePresent = true
            simulatedMonitoring.tapEnabled = true
            return
        }
        guard CGPreflightListenEventAccess() else { return }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                if let context {
                    Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context)
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if dryRun {
            simulatedMonitoring.tapPresent = false
            simulatedMonitoring.tapValid = false
            simulatedMonitoring.sourcePresent = false
            simulatedMonitoring.tapEnabled = false
            return
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CFRunLoopSourceInvalidate(tapSource)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    private func recoverMonitoringIfNeeded() {
        let state = monitoringState
        if observedMonitoringGap {
            onKeyboard?("input monitoring unavailable: \(state.unavailableReason ?? "interruption observed")")
        }
        reportMonitoringState()
        defer {
            if available && observedMonitoringGap {
                recoveredAfter = Date()
                observedMonitoringGap = false
            }
            reportMonitoringState()
        }
        guard state.unavailableReason != nil else { return }
        // Every observed gap cancels the old attempt before any operation can
        // make the listener appear healthy again. Recovery never resumes it.
        guard state.permissionGranted, !state.secureInputEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextRecoveryAt else { return }
        nextRecoveryAt = now + 1
        recoveryAttempts += 1
        if state.tapPresent && state.tapValid && state.sourcePresent {
            if dryRun { simulatedMonitoring.tapEnabled = simulatedEnableSucceeds }
            else if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        if !available {
            removeTap()
            installTap()
        }
    }

    private func reportMonitoringState() {
        let state = monitoringState
        guard state != lastReportedMonitoringState else { return }
        lastReportedMonitoringState = state
        onMonitoringChange?("input monitoring available=\(state.unavailableReason == nil) reason=\(state.unavailableReason ?? "ready") listenPermission=\(state.permissionGranted) secureInput=\(state.secureInputEnabled) tapPresent=\(state.tapPresent) tapValid=\(state.tapValid) sourcePresent=\(state.sourcePresent) tapEnabled=\(state.tapEnabled)")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "tap_timeout" : "tap_user_disabled"
            monitoringInterrupted(reason)
            return
        }
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type) {
            guard attemptActive else { return }
            let before = currentFocus()
            if mouseSelectionBaseline == nil, case .success(let snapshot) = before {
                mouseSelectionBaseline = snapshot
            }
            let epoch = attemptEpoch
            mouseChecksPending += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, self.attemptEpoch == epoch, self.attemptActive else { return }
                self.mouseChecksPending -= 1
                switch (before, self.currentFocus()) {
                case (.success(let old), .success(let new)):
                    if !old.sameSelection(as: new) { self.onFocusChange?("mouse changed caret, selection or focus") }
                default: self.onFocusChange?("cannot inspect caret/focus after mouse")
                }
            }
            return
        }
        // macOS exposes source attribution, not a guaranteed physical/synthetic bit. Only
        // explicitly attributed Typeless events are exempt; every unknown source cancels.
        let sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        if isVerifiedTypelessSource(sourcePID) { return }
        onKeyboard?("keyboard activity (including Fn/modifiers)")
    }

    private func monitoringInterrupted(_ reason: String) {
        observedMonitoringGap = true
        onMonitoringChange?("input monitoring interrupted reason=\(reason)")
        onKeyboard?("input monitoring interrupted: \(reason)")
    }

    private func isVerifiedTypelessSource(_ pid: pid_t) -> Bool {
        guard pid > 0, let source = NSRunningApplication(processIdentifier: pid) else { return false }
        let mainID = "now.typeless.desktop"
        if source.bundleIdentifier == mainID { return true }
        let mainURL = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == mainID })?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainID)
        guard let mainURL, let executable = source.executableURL, let bundle = source.bundleURL else { return false }
        let prefix = mainURL.resolvingSymlinksInPath().path + "/Contents/"
        return executable.resolvingSymlinksInPath().path.hasPrefix(prefix)
            && bundle.resolvingSymlinksInPath().path.hasPrefix(prefix)
    }

    func armAttempt(focus: FocusSnapshot) {
        attemptEpoch += 1
        attemptActive = true
        mouseChecksPending = 0
        armedFocus = focus
        mouseSelectionBaseline = nil
    }

    func endAttempt() {
        attemptEpoch += 1
        attemptActive = false
        mouseChecksPending = 0
        armedFocus = nil
        mouseSelectionBaseline = nil
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
    }

    func validateMouseSelection() {
        guard attemptActive, let baseline = mouseSelectionBaseline else { return }
        switch currentFocus() {
        case .success(let current):
            if !baseline.sameSelection(as: current) { onFocusChange?("caret/selection or focus changed after mouse") }
        case .failure(let error): onFocusChange?(error.reason)
        }
    }

    func beginAttempt() -> Result<FocusSnapshot, InputMonitorError> {
        recoverMonitoringIfNeeded()
        guard available else { return .failure(InputMonitorError(reason: "input monitoring unavailable: \(monitoringState.unavailableReason ?? "unknown")")) }
        let result = currentFocus()
        if !dryRun, case .success(let snapshot) = result, !observeFocus(pid: snapshot.processID) {
            return .failure(InputMonitorError(reason: "focus notifications unavailable"))
        }
        return result
    }

    func currentFocus() -> Result<FocusSnapshot, InputMonitorError> {
        if dryRun {
            guard focusReadable else { return .failure(InputMonitorError(reason: "cannot inspect caret/focus")) }
            guard validSelectionRange(location: simulatedFocus.selectionStart, length: simulatedFocus.selectionLength) else {
                return .failure(InputMonitorError(reason: "invalid caret/selection range"))
            }
            return .success(simulatedFocus)
        }
        guard AXIsProcessTrusted() else { return .failure(InputMonitorError(reason: "accessibility not trusted")) }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else {
            return .failure(InputMonitorError(reason: "frontmost application unavailable"))
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var windowValue: CFTypeRef?
        var inputValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &inputValue) == .success,
              let inputValue, CFGetTypeID(inputValue) == AXUIElementGetTypeID() else {
            return .failure(InputMonitorError(reason: "cannot inspect window/input focus"))
        }
        let input = inputValue as! AXUIElement
        AXUIElementSetMessagingTimeout(input, 0.08)
        var rangeValue: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(input, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return .failure(InputMonitorError(reason: "cannot inspect caret/selection"))
        }
        guard validSelectionRange(location: range.location, length: range.length) else {
            return .failure(InputMonitorError(reason: "invalid caret/selection range"))
        }
        return .success(FocusSnapshot(bundleID: bundleID, processID: front.processIdentifier,
            window: (windowValue as! AXUIElement), input: input, selectionStart: range.location, selectionLength: range.length))
    }

    private func observeFocus(pid: pid_t) -> Bool {
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        var observer: AXObserver?
        guard AXObserverCreate(pid, { observer, _, _, context in
            if let context {
                let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                guard let activeObserver = monitor.focusObserver, CFEqual(observer, activeObserver) else { return }
                guard monitor.attemptActive, let original = monitor.armedFocus else { return }
                if case .success(let current) = monitor.currentFocus(), !original.sameTarget(as: current) {
                    monitor.onFocusChange?("window/input focus changed")
                } else {
                    // AX notifications do not carry a reliable old/new focus pair. A same-target
                    // snapshot may already be a switch back, so fail closed rather than miss it.
                    monitor.onFocusChange?("focus change notification could not be resolved reliably")
                }
            }
        }, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
            guard AXObserverAddNotification(observer, app, notification as CFString, context) == .success else { return false }
        }
        focusObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return true
    }

    func poll() {
        defer { recoverMonitoringIfNeeded() }
        guard dryRun, let eventPath else { return }
        guard let data = FileManager.default.contents(atPath: eventPath), data.count >= eventOffset else {
            simulatedMonitoring.permissionGranted = false
            onKeyboard?("simulated input stream unavailable")
            return
        }
        let unread = data.subdata(in: eventOffset..<data.count)
        guard let lastNewline = unread.lastIndex(of: 10) else { return }
        let complete = unread.prefix(through: lastNewline)
        eventOffset += complete.count
        for line in complete.split(separator: 10) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                simulatedMonitoring.permissionGranted = false
                onKeyboard?("simulated input event invalid")
                continue
            }
            if json["type"] as? String == "keyboard",
               !["typeless", "typeless-helper-verified"].contains(json["origin"] as? String ?? "unknown") {
                onKeyboard?("keyboard activity (including Fn/modifiers)")
            }
            let type = json["type"] as? String
            if type == "monitoring" {
                if let value = json["enableSucceeds"] as? Bool { simulatedEnableSucceeds = value }
                if let value = json["createSucceeds"] as? Bool { simulatedCreateSucceeds = value }
                switch json["tap"] as? String {
                case "timeout", "user_disabled":
                    simulatedMonitoring.tapEnabled = false
                    monitoringInterrupted(json["tap"] as? String == "timeout" ? "tap_timeout" : "tap_user_disabled")
                case "invalid": simulatedMonitoring.tapValid = false
                case "missing": simulatedMonitoring.tapPresent = false
                case "source_missing": simulatedMonitoring.sourcePresent = false
                default: break
                }
            }
            if type == "capability" {
                if let value = json["inputMonitoring"] as? Bool { simulatedMonitoring.permissionGranted = value }
                if let value = json["focusReadable"] as? Bool { focusReadable = value }
                if let value = json["secureInput"] as? Bool { simulatedMonitoring.secureInputEnabled = value }
                if !available {
                    observedMonitoringGap = true
                    onKeyboard?("input monitoring unavailable")
                }
                if !focusReadable { onFocusChange?("cannot inspect caret/focus") }
            }
            if type == "focus" || type == "state" || type == "mouse" {
                let before = simulatedFocus
                if type == "mouse", attemptActive, mouseSelectionBaseline == nil { mouseSelectionBaseline = before }
                if let app = json["app"] as? String { simulatedFocus.bundleID = app }
                if let window = json["window"] as? String { simulatedFocus.windowToken = window }
                if let input = json["input"] as? String { simulatedFocus.inputToken = input }
                if let caret = json["caret"] as? Int { simulatedFocus.selectionStart = caret }
                if let length = json["selectionLength"] as? Int { simulatedFocus.selectionLength = length }
                if type == "mouse", !before.sameSelection(as: simulatedFocus) {
                    onFocusChange?("mouse changed caret, selection or focus")
                } else if !before.sameTarget(as: simulatedFocus) {
                    onFocusChange?("window/input/application focus changed")
                }
            }
        }
    }
}
