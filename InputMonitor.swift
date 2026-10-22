import AppKit
import ApplicationServices
import Carbon
import Foundation
import Synchronization

struct FocusSnapshot {
    var bundleID: String
    var processID: pid_t = 0
    var window: AXUIElement?
    var input: AXUIElement?
    var windowToken = "window-1"
    var inputToken = "input-1"
    var selectionStart = 0
    var selectionLength = 0
    var text = ""

    func sameTarget(as other: FocusSnapshot) -> Bool {
        guard normalizeBundleID(bundleID) == normalizeBundleID(other.bundleID), processID == other.processID,
              windowToken == other.windowToken, inputToken == other.inputToken else { return false }
        if let window, let otherWindow = other.window, !CFEqual(window, otherWindow) { return false }
        if let input, let otherInput = other.input, !CFEqual(input, otherInput) { return false }
        return (window == nil) == (other.window == nil) && (input == nil) == (other.input == nil)
    }

    func sameSelection(as other: FocusSnapshot) -> Bool {
        sameTarget(as: other) && selectionStart == other.selectionStart && selectionLength == other.selectionLength && text == other.text
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

// These conservative policy decisions are shared by native input and the
// dry-run boundary; simulated transitions cannot bypass the production policy.
private enum TransitionDecision { case preserve, cancel, send }
private func keyboardDecision(code: Int64, flags: CGEventFlags, repeated: Bool, role: String?, ascii: Bool) -> TransitionDecision {
    if code == 48 && flags.contains(.maskCommand) { return .preserve }
    guard code == 48, !repeated, flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty,
          role == kAXTextFieldRole, ascii else { return .cancel }
    return .send
}
private func mouseDecision(left: Bool, flags: CGEventFlags, role: String?, separate: Bool) -> TransitionDecision {
    guard left, flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
          role == kAXTextFieldRole || role == kAXTextAreaRole, separate else { return .cancel }
    return .send
}

// The only simulated system boundary is enabled by TYPELESS_DRY_RUN. It never posts keys.
final class InputMonitor {
    let dryRun: Bool
    private let eventPath: String?
    private let manualTestSettlement: Bool
    private var eventOffset = 0
    // All attempt/tap state is shared with the dedicated event thread. Callbacks
    // consume the attempt synchronously; reporting to the main loop is asynchronous.
    private let stateLock = NSRecursiveLock()
    // A busy main-loop AX read must never hold up a physical input event.
    // Missing even one event invalidates the attempt before a later send.
    private let missedEvent = Atomic<Bool>(false)
    private var verifiedTypelessPIDs: Set<pid_t> = []
    private var nextSourceRefresh: TimeInterval = 0
    private let eventThreadReady = DispatchSemaphore(value: 0)
    private var eventThread: Thread?
    private var eventRunLoop: CFRunLoop?
    private var authorizeSend: (() -> Bool)?
    private var settled = false
    private var sentOnEventThread = false
    private var lastSendReason = "original-pid"
    var sentReason: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastSendReason
    }
    var sentAwaitingReport: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return sentOnEventThread
    }
    private var returnEvents: [CGEvent] = []
    private static let eventMarker: Int64 = 0x545950454C455353
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var focusObserver: AXObserver?
    private var simulatedOriginalFocus: FocusSnapshot?
    private var simulatedFocus: FocusSnapshot
    private var focusReadable = true
    private var simulatedMonitoring = InputMonitoringState()
    private var simulatedEnableSucceeds = true
    private var simulatedCreateSucceeds = true
    private var attemptEpoch = 0
    private var attemptActive = false
    private var armedFocus: FocusSnapshot?
    private var nextRecoveryAt: TimeInterval = 0
    private var lastReportedMonitoringState: InputMonitoringState?
    private var observedMonitoringGap = false
    private(set) var recoveredAfter: Date?
    private(set) var recoveryAttempts = 0
    private var monitoringState: InputMonitoringState {
        stateLock.lock(); defer { stateLock.unlock() }
        let state: InputMonitoringState
        if dryRun { state = simulatedMonitoring }
        else {
            state = InputMonitoringState(permissionGranted: CGPreflightListenEventAccess(),
                secureInputEnabled: IsSecureEventInputEnabled(), tapPresent: tap != nil,
                tapValid: tap.map { CFMachPortIsValid($0) } ?? false,
                sourcePresent: tapSource.map { CFRunLoopSourceIsValid($0) && CFRunLoopContainsSource(eventRunLoop, $0, .commonModes) } ?? false,
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
    var onSent: ((String) -> Void)?
    var onKeyboard: ((String) -> Void)?
    var onFocusChange: ((String) -> Void)?
    var onMonitoringChange: ((String) -> Void)?

    init(dryRun: Bool, environment: [String: String]) {
        self.dryRun = dryRun
        manualTestSettlement = dryRun && environment["TYPELESS_TEST_MANUAL_SETTLE"] == "1"
        eventPath = dryRun ? environment["TYPELESS_TEST_EVENTS"] : nil
        simulatedFocus = FocusSnapshot(bundleID: environment["TYPELESS_FAKE_FRONT"] ?? "dry-run")
        if !dryRun {
            eventThread = Thread { [weak self] in
                guard let self else { return }
                self.eventRunLoop = CFRunLoopGetCurrent()
                // Keep the event thread alive even when permissions initially deny a tap.
                let keepAlive = Port()
                RunLoop.current.add(keepAlive, forMode: .default)
                self.eventThreadReady.signal()
                CFRunLoopRun()
            }
            eventThread?.name = "typeless-autosend.events"
            eventThread?.qualityOfService = .userInteractive
            eventThread?.start()
            eventThreadReady.wait()
            installTap()
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
            options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                if let context {
                    Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue().handle(proxy, type, event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context)
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        tapSource = source
        CFRunLoopAddSource(eventRunLoop, source, .commonModes)
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
            CFRunLoopRemoveSource(eventRunLoop, tapSource, .commonModes)
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

    private func cancelFromEvent(_ reason: String) {
        guard attemptActive else { return }
        attemptActive = false
        if dryRun { onKeyboard?(reason) }
        else {
            let epoch = attemptEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                guard self.attemptEpoch == epoch else { return }
                self.onKeyboard?(reason)
            }
        }
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) {
        // Own keys cannot invalidate a later attempt even if main holds the lock.
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
        guard stateLock.try() else {
            missedEvent.store(true, ordering: .releasing)
            return
        }
        defer { stateLock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            observedMonitoringGap = true
            cancelFromEvent("input monitoring interrupted")
            return
        }
        guard attemptActive, let original = armedFocus,
              event.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return }
        if missedEvent.load(ordering: .acquiring) { cancelFromEvent("input event arrived during state inspection"); return }
        // Querying the receiving application's AX focus is necessary: cached
        // geometry alone cannot prove that focus has not changed in the meantime.
        let isMouse = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) { return }
        if verifiedTypelessPIDs.contains(pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))) { return }
        if isMouse {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.005)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(event.location.x), Float(event.location.y), &hit) == .success,
                  let hit else { cancelFromEvent("cannot classify mouse target"); return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success else { cancelFromEvent("cannot identify mouse application"); return }
            // External clicks must leave the original countdown intact.
            guard pid == original.processID else { return }
            // A click activating the original background app is an application
            // switch, not a same-application transition. Preserve its deadline.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == original.processID else { return }
            let role = attribute(hit, kAXRoleAttribute, deadline: deadline) as? String
            let separate = original.input.map { !CFEqual(hit, $0) && separateEditableTarget(hit, from: $0, deadline: deadline) } ?? false
            guard mouseDecision(left: type == .leftMouseDown, flags: event.flags, role: role, separate: separate) == .send else {
                cancelFromEvent("mouse editing or uncertain focus transition"); return
            }
        } else {
            if type == .flagsChanged, event.flags.contains(.maskSecondaryFn) {
                cancelFromEvent("Fn activity (new dictation)"); return
            }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontPID == original.processID else { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .flagsChanged { return }
            if type == .keyUp { return }
            // Command-Tab changes application; modifiers alone do not edit text.
            let role = code == 48 ? original.input.flatMap { attribute($0, kAXRoleAttribute, deadline: deadline) as? String } : nil
            let decision = keyboardDecision(code: code, flags: event.flags,
                repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                role: role, ascii: code == 48 && asciiInputSource())
            if decision == .preserve { return }
            guard type == .keyDown, decision == .send else {
                cancelFromEvent("keyboard editing or uncertain focus transition"); return
            }
        }
        sendBeforeTransition(proxy: proxy, deadline: deadline)
    }

    private func separateEditableTarget(_ hit: AXUIElement, from original: AXUIElement, deadline: TimeInterval) -> Bool {
        // Prove that both leaves belong to distinct branches of an AX window.
        // Composite editors can expose several AX objects for the same editor.
        func ancestry(_ leaf: AXUIElement) -> [AXUIElement]? {
            var result = [leaf]
            var current = leaf
            for _ in 0..<12 {
                guard let role = attribute(current, kAXRoleAttribute, deadline: deadline) as? String else { return nil }
                if role == kAXWindowRole { return result }
                if result.count > 1, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return nil }
                guard let parent = attribute(current, kAXParentAttribute, deadline: deadline), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                current = parent as! AXUIElement
                if result.contains(where: { CFEqual($0, current) }) { return nil }
                result.append(current)
            }
            return nil
        }
        guard attribute(hit, kAXEnabledAttribute, deadline: deadline) as? Bool == true,
              let hitPath = ancestry(hit), let originalPath = ancestry(original),
              !hitPath.contains(where: { CFEqual($0, original) }),
              !originalPath.contains(where: { CFEqual($0, hit) }) else { return false }
        var focusSettable = DarwinBoolean(false)
        AXUIElementSetMessagingTimeout(hit, 0.005)
        guard ProcessInfo.processInfo.systemUptime < deadline,
              AXUIElementIsAttributeSettable(hit, kAXFocusedAttribute as CFString, &focusSettable) == .success,
              focusSettable.boolValue else { return false }
        return ProcessInfo.processInfo.systemUptime < deadline
    }

    private func sendBeforeTransition(proxy: CGEventTapProxy?, deadline: TimeInterval) {
        guard settled, authorizeSend?() == true,
              ProcessInfo.processInfo.systemUptime < deadline,
              case .success = validateAttempt(deadline: deadline),
              available, dryRun || AXIsProcessTrusted(), returnEvents.count == 2,
              !missedEvent.load(ordering: .acquiring),
              dryRun || NSWorkspace.shared.frontmostApplication?.processIdentifier == armedFocus?.processID,
              ProcessInfo.processInfo.systemUptime < deadline else {
            cancelFromEvent("cannot verify original input before focus transition"); return
        }
        attemptActive = false
        sentOnEventThread = true
        lastSendReason = "before-focus-change"
        if let proxy, !dryRun { for key in returnEvents { key.tapPostEvent(proxy) } }
        if dryRun { onSent?("before-focus-change"); return }
        let epoch = attemptEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            guard self.attemptEpoch == epoch else { return }
            self.onSent?("before-focus-change")
        }
    }

    private func asciiInputSource() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(property).takeUnretainedValue())
    }

    private func monitoringInterrupted(_ reason: String) {
        observedMonitoringGap = true
        onMonitoringChange?("input monitoring interrupted reason=\(reason)")
        onKeyboard?("input monitoring interrupted: \(reason)")
    }

    private func refreshTypelessSources() {
        let applications = NSWorkspace.shared.runningApplications
        let mainID = "now.typeless.desktop"
        let mainURL = applications.first(where: { $0.bundleIdentifier == mainID })?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainID)
        let prefix = mainURL.map { $0.resolvingSymlinksInPath().path + "/Contents/" }
        verifiedTypelessPIDs = Set(applications.compactMap { source in
            if source.bundleIdentifier == mainID { return source.processIdentifier }
            guard let prefix, let executable = source.executableURL, let bundle = source.bundleURL,
                  executable.resolvingSymlinksInPath().path.hasPrefix(prefix),
                  bundle.resolvingSymlinksInPath().path.hasPrefix(prefix) else { return nil }
            return source.processIdentifier
        })
    }

    func armAttempt(focus: FocusSnapshot, authorize: @escaping () -> Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        authorizeSend = authorize
        missedEvent.store(false, ordering: .releasing)
        settled = false
        sentOnEventThread = false
        returnEvents = [true, false].compactMap { down in
            guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 0x24, keyDown: down) else { return nil }
            key.flags = []
            key.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            key.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(focus.processID))
            return key
        }
        attemptEpoch += 1
        attemptActive = true
        armedFocus = focus
        simulatedOriginalFocus = focus
        if !dryRun, let observer = focusObserver, let input = focus.input {
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                guard AXObserverAddNotification(observer, input, notification as CFString, context) == .success else {
                    cancelFromEvent("content/selection notifications unavailable"); return
                }
            }
        }
    }

    @discardableResult
    func endAttempt() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        // Cancellation and observing a completed send are one atomic operation.
        // A queued timer cannot post between the caller's decision and disarm.
        let outcome = sentOnEventThread ? lastSendReason : nil
        authorizeSend = nil
        sentOnEventThread = false
        returnEvents = []
        attemptEpoch += 1
        attemptActive = false
        armedFocus = nil
        if let focusObserver {
            CFRunLoopRemoveSource(eventRunLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        return outcome
    }

    func beginAttempt() -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        recoverMonitoringIfNeeded()
        guard available else { return .failure(InputMonitorError(reason: "input monitoring unavailable: \(monitoringState.unavailableReason ?? "unknown")")) }
        let result = currentFocus()
        if !dryRun, case .success(let snapshot) = result, !observeFocus(pid: snapshot.processID) {
            return .failure(InputMonitorError(reason: "focus notifications unavailable"))
        }
        return result
    }

    private func attribute(_ element: AXUIElement, _ name: String, deadline: TimeInterval) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.005)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    func currentFocus() -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        if dryRun { return inspectFocus(simulatedFocus, deadline: .infinity) }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else {
            return .failure(InputMonitorError(reason: "frontmost application unavailable"))
        }
        return inspectFocus(FocusSnapshot(bundleID: bundleID, processID: front.processIdentifier), deadline: ProcessInfo.processInfo.systemUptime + 0.025)
    }

    private func inspectFocus(_ target: FocusSnapshot, deadline: TimeInterval) -> Result<FocusSnapshot, InputMonitorError> {
        if dryRun {
            guard focusReadable else { return .failure(InputMonitorError(reason: "cannot inspect caret/focus")) }
            guard validSelectionRange(location: target.selectionStart, length: target.selectionLength) else {
                return .failure(InputMonitorError(reason: "invalid caret/selection range"))
            }
            return .success(target)
        }
        guard AXIsProcessTrusted(), NSRunningApplication(processIdentifier: target.processID)?.isTerminated == false else {
            return .failure(InputMonitorError(reason: "original application unavailable or accessibility not trusted"))
        }
        let app = AXUIElementCreateApplication(target.processID)
        guard let windowValue = attribute(app, kAXFocusedWindowAttribute, deadline: deadline), CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              let inputValue = attribute(app, kAXFocusedUIElementAttribute, deadline: deadline), CFGetTypeID(inputValue) == AXUIElementGetTypeID() else {
            return .failure(InputMonitorError(reason: "cannot inspect window/input focus"))
        }
        let input = inputValue as! AXUIElement
        var range = CFRange()
        guard let rangeValue = attribute(input, kAXSelectedTextRangeAttribute, deadline: deadline), CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              validSelectionRange(location: range.location, length: range.length),
              let text = attribute(input, kAXValueAttribute, deadline: deadline) as? String,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .failure(InputMonitorError(reason: "cannot inspect content/caret/selection within budget"))
        }
        return .success(FocusSnapshot(bundleID: target.bundleID, processID: target.processID,
            window: (windowValue as! AXUIElement), input: input, selectionStart: range.location, selectionLength: range.length, text: text))
    }

    // Typeless may finish its paste during the existing 150 ms paste buffer.
    // Freeze content and selection after that buffer, never after user editing.
    func settleAttempt(testEvent: Bool = false) {
        stateLock.lock(); defer { stateLock.unlock() }
        // Test-only phase control avoids asserting on a wall-clock race. The
        // real service always uses its normal 150 ms dispatch deadline.
        guard !manualTestSettlement || testEvent else { return }
        guard attemptActive, let original = armedFocus else { return }
        let target = dryRun && normalizeBundleID(simulatedFocus.bundleID) != normalizeBundleID(original.bundleID)
            ? simulatedOriginalFocus ?? original : (dryRun ? simulatedFocus : original)
        let result = inspectFocus(target, deadline: ProcessInfo.processInfo.systemUptime + 0.025)
        guard case .success(let current) = result, original.sameTarget(as: current) else {
            cancelFromEvent("cannot settle original input"); return
        }
        armedFocus = current
        settled = true
    }

    func validateAttempt(deadline: TimeInterval? = nil) -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        guard attemptActive, !missedEvent.load(ordering: .acquiring), let original = armedFocus else { return .failure(InputMonitorError(reason: "attempt already consumed, cancelled or input inspection interrupted")) }
        let result: Result<FocusSnapshot, InputMonitorError>
        if dryRun {
            // The seam retains the original application's last focus while another is active.
            result = inspectFocus(normalizeBundleID(simulatedFocus.bundleID) == normalizeBundleID(original.bundleID) ? simulatedFocus : simulatedOriginalFocus ?? original, deadline: .infinity)
        } else { result = inspectFocus(original, deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 0.025) }
        guard case .success(let current) = result else { return result }
        guard original.sameTarget(as: current), !settled || original.sameSelection(as: current) else {
            return .failure(InputMonitorError(reason: "original content/caret/selection or focus changed"))
        }
        return .success(current)
    }

    func deliver(completion: @escaping (Bool) -> Void) {
        stateLock.lock()
        let epoch = attemptEpoch
        stateLock.unlock()
        let operation = { [self] in
            guard stateLock.try() else {
                // This is a timer job, not a missed physical input. An old
                // delivery must not invalidate a newly armed attempt.
                DispatchQueue.main.async { completion(false) }
                return
            }
            defer { stateLock.unlock() }
            let safe = epoch == attemptEpoch && settled && authorizeSend?() == true && {
                if case .success = validateAttempt() { return true }; return false
            }() && available && (dryRun || AXIsProcessTrusted())
                && returnEvents.count == 2 && !missedEvent.load(ordering: .acquiring)
            if safe, let original = armedFocus {
                attemptActive = false
                sentOnEventThread = true
                lastSendReason = "original-pid"
                if !dryRun { for key in returnEvents { key.postToPid(original.processID) } }
            }
            DispatchQueue.main.async { completion(safe) }
        }
        if dryRun { operation() }
        else if let eventRunLoop {
            CFRunLoopPerformBlock(eventRunLoop, CFRunLoopMode.commonModes.rawValue, operation)
            CFRunLoopWakeUp(eventRunLoop)
        } else { completion(false) }
    }

    private func observeFocus(pid: pid_t) -> Bool {
        if let focusObserver {
            CFRunLoopRemoveSource(eventRunLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        var observer: AXObserver?
        guard AXObserverCreate(pid, { observer, element, notification, context in
            if let context {
                let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                guard monitor.stateLock.try() else {
                    monitor.missedEvent.store(true, ordering: .releasing)
                    return
                }
                defer { monitor.stateLock.unlock() }
                guard let activeObserver = monitor.focusObserver, CFEqual(observer, activeObserver) else { return }
                guard monitor.attemptActive, let original = monitor.armedFocus else { return }
                if [kAXValueChangedNotification, kAXSelectedTextChangedNotification].contains(notification as String) {
                    if monitor.settled { monitor.cancelFromEvent("original content/caret/selection changed") }
                    return
                }
                var notified = original
                if notification as String == kAXFocusedUIElementChangedNotification { notified.input = element }
                else { notified.window = element }
                monitor.handleFocusNotification(notified)
            }
        }, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
            guard AXObserverAddNotification(observer, app, notification as CFString, context) == .success else { return false }
        }
        focusObserver = observer
        CFRunLoopAddSource(eventRunLoop, AXObserverGetRunLoopSource(observer), .commonModes)
        return true
    }

    private func handleFocusNotification(_ notified: FocusSnapshot) {
        guard attemptActive, let original = armedFocus else { return }
        // AX focus notifications identify the newly focused element. Check that
        // payload as well as the current snapshot: a different payload still
        // cancels if focus has already returned before this callback runs.
        guard original.sameTarget(as: notified) else {
            cancelFromEvent("window/input focus changed")
            return
        }
        switch validateAttempt() {
        case .success(let current):
            if !original.sameTarget(as: current) { cancelFromEvent("window/input focus changed") }
        case .failure(let error):
            cancelFromEvent("cannot verify focus notification: \(error.reason)")
        }
    }

    func poll() {
        stateLock.lock(); defer { stateLock.unlock() }
        defer { recoverMonitoringIfNeeded() }
        if !dryRun, ProcessInfo.processInfo.systemUptime >= nextSourceRefresh {
            nextSourceRefresh = ProcessInfo.processInfo.systemUptime + 1
            refreshTypelessSources()
        }
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
               !["typeless", "typeless-helper-verified"].contains(json["origin"] as? String ?? "unknown"),
               (json["key"] as? String == "fn" || (armedFocus.map({ normalizeBundleID($0.bundleID) == normalizeBundleID(simulatedFocus.bundleID) }) ?? false)) {
                if json["key"] as? String != "command-tab" {
                    cancelFromEvent("keyboard activity (including Fn/modifiers)")
                }
            }
            let type = json["type"] as? String
            if type == "settle", manualTestSettlement { settleAttempt(testEvent: true) }
            if type == "transition", attemptActive {
                let targetApp = json["app"] as? String ?? simulatedFocus.bundleID
                if normalizeBundleID(targetApp) == normalizeBundleID(armedFocus?.bundleID ?? "") {
                    var flags = CGEventFlags()
                    for flag in json["modifiers"] as? [String] ?? [] {
                        switch flag {
                        case "command": flags.insert(.maskCommand)
                        case "shift": flags.insert(.maskShift)
                        case "control": flags.insert(.maskControl)
                        case "option": flags.insert(.maskAlternate)
                        default: flags.insert(.maskSecondaryFn)
                        }
                    }
                    let decision: TransitionDecision
                    if json["kind"] as? String == "tab" {
                        decision = keyboardDecision(code: 48, flags: flags, repeated: json["repeat"] as? Bool ?? false,
                            role: json["sourceRole"] as? String ?? kAXTextFieldRole, ascii: json["ascii"] as? Bool ?? true)
                    } else {
                        decision = mouseDecision(left: json["left"] as? Bool ?? true, flags: flags,
                            role: json["targetRole"] as? String ?? kAXTextFieldRole,
                            separate: json["verified"] as? Bool == true)
                    }
                    if decision == .send { sendBeforeTransition(proxy: nil, deadline: ProcessInfo.processInfo.systemUptime + 0.025) }
                    else if decision == .cancel { cancelFromEvent("mouse/keyboard editing or uncertain focus transition") }
                }
            }
            if type == "edit_notification", settled { cancelFromEvent("original content/caret/selection changed") }
            if type == "focus_notification", var notified = armedFocus {
                if let readable = json["focusReadable"] as? Bool { focusReadable = readable }
                if let window = json["window"] as? String { notified.windowToken = window }
                if let input = json["input"] as? String { notified.inputToken = input }
                handleFocusNotification(notified)
            }
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
                if let app = json["app"] as? String {
                    if let original = armedFocus, normalizeBundleID(before.bundleID) == normalizeBundleID(original.bundleID) { simulatedOriginalFocus = before }
                    if let retained = simulatedOriginalFocus, normalizeBundleID(retained.bundleID) == normalizeBundleID(app) { simulatedFocus = retained }
                    simulatedFocus.bundleID = app
                }
                if let window = json["window"] as? String { simulatedFocus.windowToken = window }
                if let input = json["input"] as? String { simulatedFocus.inputToken = input }
                if let caret = json["caret"] as? Int { simulatedFocus.selectionStart = caret }
                if let length = json["selectionLength"] as? Int { simulatedFocus.selectionLength = length }
                if let text = json["text"] as? String { simulatedFocus.text = text }
                if type == "mouse", !before.sameSelection(as: simulatedFocus) {
                    onFocusChange?("mouse changed caret, selection or focus")
                } else if normalizeBundleID(before.bundleID) == normalizeBundleID(simulatedFocus.bundleID), !before.sameTarget(as: simulatedFocus) {
                    onFocusChange?("window/input/application focus changed")
                }
            }
        }
    }
}
