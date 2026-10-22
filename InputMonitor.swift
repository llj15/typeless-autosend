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
    var selectionAvailable = true
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

enum InputTargetRelation: Equatable { case inside, outside, unknown }
enum InputParentStep<Element> {
    case parent(Element)
    case boundary
    case unavailable
}

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
    private let manualTestSettlement: Bool
    private let requirePasteCapture: Bool
    private var eventOffset = 0
    // All attempt/tap state is shared with the dedicated event thread. Callbacks
    // consume the attempt synchronously; reporting to the main loop is asynchronous.
    private let stateLock = NSRecursiveLock()
    // A busy AX read must never hold up a physical input event. Only a missed
    // actionable mouse event or real monitoring gap invalidates an attempt.
    private let missedEvent = Atomic<Bool>(false)
    private let missedPasteCapture = Atomic<Bool>(false)
    // Source identity can be checked without acquiring the AX/state lock. This
    // small lock protects only a cached set and never spans an AX/database read.
    private let sourcePIDLock = NSLock()
    private var sourcePIDs: Set<pid_t> = []
    private var verifiedTypelessPIDs: Set<pid_t> {
        get { sourcePIDLock.lock(); defer { sourcePIDLock.unlock() }; return sourcePIDs }
        set { sourcePIDLock.lock(); defer { sourcePIDLock.unlock() }; sourcePIDs = newValue }
    }
    private var nextSourceRefresh: TimeInterval = 0
    private let eventThreadReady = DispatchSemaphore(value: 0)
    private var eventThread: Thread?
    private var eventRunLoop: CFRunLoop?
    private var authorizeSend: (() -> Bool)?
    private var settled = false
    private struct PasteCapture {
        var focus: FocusSnapshot
        var recordID: String?
        var capturedAt: TimeInterval
        var departed = false
    }
    private var pasteCapture: PasteCapture?
    private var consumedPaste: PasteCapture?
    private var pasteBaseline: PasteBaseline?
    private var pastedText = ""
    private var pendingDeparture: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var simulatedProcessAlive = true
    private var simulatedAccessibilityTrusted = true
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
    private var simulatedOriginalApplicationFocus: FocusSnapshot?
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
    private var recordIDProvider: (() -> String?)?
    var pasteRecordIDProvider: (() -> String?)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return recordIDProvider }
        set { stateLock.lock(); defer { stateLock.unlock() }; recordIDProvider = newValue }
    }
    var onSent: ((String) -> Void)?
    var onKeyboard: ((String) -> Void)?
    var onFocusChange: ((String) -> Void)?
    var onMonitoringChange: ((String) -> Void)?

    init(dryRun: Bool, environment: [String: String]) {
        self.dryRun = dryRun
        requirePasteCapture = !dryRun || environment["TYPELESS_TEST_REQUIRE_PASTE"] == "1"
        manualTestSettlement = dryRun && environment["TYPELESS_TEST_MANUAL_SETTLE"] == "1"
        eventPath = dryRun ? environment["TYPELESS_TEST_EVENTS"] : nil
        simulatedFocus = FocusSnapshot(bundleID: environment["TYPELESS_FAKE_FRONT"] ?? "dry-run")
        if dryRun, let pid = environment["TYPELESS_TEST_TYPELESS_PID"].flatMap(Int32.init) {
            verifiedTypelessPIDs = [pid]
        }
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
            refreshTypelessSources()
            installTap()
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil, queue: nil) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.applicationDeactivated(pid: application.processIdentifier)
            })
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: nil) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.applicationTerminated(pid: application.processIdentifier)
            })
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
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                if let context {
                    Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue().handleEvent(type, event)
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
            cancelFromEvent("input monitoring unavailable")
            pasteCapture = nil
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

    func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return }
        let keyboard = [.keyDown, .keyUp, .flagsChanged].contains(type)
        let pasteChord = type == .keyDown &&
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V) && event.flags.contains(.maskCommand)
        // Ordinary keys carry no policy decision, so they never contend with a
        // main-thread AX read. Source verification matters only for paste capture.
        if keyboard && !pasteChord { return }
        let typeless = verifiedTypelessPIDs.contains(pid_t(event.getIntegerValueField(.eventSourceUnixProcessID)))
        let typelessPaste = pasteChord && typeless
        if keyboard && !typelessPaste { return }
        let interrupted = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        let mouseDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        guard typelessPaste || interrupted || mouseDown else { return }
        guard stateLock.try() else {
            if typelessPaste { missedPasteCapture.store(true, ordering: .releasing) }
            else { missedEvent.store(true, ordering: .releasing) }
            return
        }
        defer { stateLock.unlock() }
        if interrupted {
            observedMonitoringGap = true
            pasteCapture = nil
            cancelFromEvent("input monitoring interrupted")
            return
        }
        // Capture before the event is released, even when the database has not
        // announced a completed transcript yet. Only verified sources qualify.
        if typelessPaste { capturePaste(); return }
        if typeless { return }
        let original: FocusSnapshot
        if attemptActive, let armedFocus { original = armedFocus }
        else if let capture = pasteCapture { original = capture.focus }
        else { return }
        if missedEvent.load(ordering: .acquiring) {
            if attemptActive { cancelFromEvent("input event arrived during state inspection") }
            return
        }
        guard mouseDown, originalIsFrontmost(original) else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.005)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(event.location.x), Float(event.location.y), &hit) == .success,
              let hit else { return } // Deactivation handles clicks into another application.
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == original.processID else { return }
        let relation = original.input.map { classifyInputTarget(hit, $0, deadline: deadline) } ?? .unknown
        handleMouseTarget(relation, hitPID: pid)
    }

    // Shared by native hit testing and the pure dry-run boundary. A click may
    // leave after paste capture but before the completed database row arms it.
    func handleMouseTarget(_ relation: InputTargetRelation, hitPID: pid_t) {
        stateLock.lock(); defer { stateLock.unlock() }
        let original = attemptActive ? armedFocus : pasteCapture?.focus
        guard relation == .outside, let original, hitPID == original.processID,
              originalIsFrontmost(original) else { return }
        if attemptActive {
            if settled, case .failure = validateAttempt() { return }
            requestDeparture("before-focus-change")
        } else { pasteCapture?.departed = true }
    }

    // Only a completed ancestry walk can prove that two objects are outside
    // one another. Missing parents, timeouts, cycles and excessive depth leave
    // classification unknown; focus/deactivation notifications remain active.
    static func classifyInputTarget<Element>(hit: Element, original: Element,
            equal: (Element, Element) -> Bool, parentStep: (Element) -> InputParentStep<Element>,
            maximumDepth: Int = 24) -> InputTargetRelation {
        if equal(hit, original) { return .inside }
        func ancestry(_ leaf: Element) -> ([Element], Bool) {
            var nodes: [Element] = []
            var current = leaf
            for _ in 0..<maximumDepth {
                if nodes.contains(where: { equal($0, current) }) { return (nodes, false) }
                switch parentStep(current) {
                case .boundary: return (nodes, true)
                case .unavailable: return (nodes, false)
                case .parent(let parent): nodes.append(current); current = parent
                }
            }
            return (nodes, false)
        }
        let hitPath = ancestry(hit)
        if hitPath.0.contains(where: { equal($0, original) }) { return .inside }
        let originalPath = ancestry(original)
        if originalPath.0.contains(where: { equal($0, hit) }) { return .inside }
        return hitPath.1 && originalPath.1 ? .outside : .unknown
    }

    private func classifyInputTarget(_ hit: AXUIElement, _ original: AXUIElement,
                                     deadline: TimeInterval) -> InputTargetRelation {
        Self.classifyInputTarget(hit: hit, original: original, equal: { CFEqual($0, $1) }, parentStep: { element in
            guard let role = self.attribute(element, kAXRoleAttribute, deadline: deadline) as? String else { return .unavailable }
            if [kAXWindowRole, kAXApplicationRole].contains(role) { return .boundary }
            guard let parent = self.attribute(element, kAXParentAttribute, deadline: deadline),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unavailable }
            return .parent(parent as! AXUIElement)
        })
    }

    private func capturePaste() {
        missedPasteCapture.store(false, ordering: .releasing)
        pasteCapture = nil
        guard available, case .success(let snapshot) = currentFocus() else { return }
        pasteCapture = PasteCapture(focus: snapshot, recordID: pasteRecordIDProvider?(), capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    private func originalIsFrontmost(_ original: FocusSnapshot) -> Bool {
        if dryRun { return normalizeBundleID(simulatedFocus.bundleID) == normalizeBundleID(original.bundleID) }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == original.processID
    }

    private func applicationDeactivated(pid: pid_t) {
        guard stateLock.try() else { missedEvent.store(true, ordering: .releasing); return }
        defer { stateLock.unlock() }
        if pasteCapture?.focus.processID == pid { pasteCapture?.departed = true }
        guard armedFocus?.processID == pid else { return }
        requestDeparture("original-pid")
    }

    private func applicationTerminated(pid: pid_t) {
        guard stateLock.try() else { missedEvent.store(true, ordering: .releasing); return }
        defer { stateLock.unlock() }
        if pasteCapture?.focus.processID == pid { pasteCapture = nil }
        if armedFocus?.processID == pid { cancelFromEvent("original application exited") }
    }

    private func requestDeparture(_ reason: String) {
        guard attemptActive else { return }
        guard settled else { pendingDeparture = reason; return }
        // An edit can precede its queued AX notification or foreground poll.
        // Take one final snapshot of the captured input object at departure;
        // subsequent background activity is never polled for content changes.
        if let original = armedFocus {
            guard originalIdentityUnchanged(original) else { return }
            let target = dryRun ? (simulatedOriginalFocus ?? original) : original
            if case .success(let current) = inspectInput(target, deadline: ProcessInfo.processInfo.systemUptime + 0.025),
               contentWasEdited(current, baseline: original) {
                cancelFromEvent("original content/caret/selection changed")
                return
            }
        }
        _ = sendNow(reason: reason)
    }

    private func healthyForSend() -> Bool {
        guard attemptActive, available, !observedMonitoringGap,
              !missedEvent.load(ordering: .acquiring), let original = armedFocus else { return false }
        if dryRun { return simulatedProcessAlive && simulatedAccessibilityTrusted }
        return AXIsProcessTrusted() && NSRunningApplication(processIdentifier: original.processID)?.isTerminated == false
    }

    @discardableResult
    private func sendNow(reason: String, report: Bool = true) -> Bool {
        guard settled, healthyForSend(), authorizeSend?() == true, healthyForSend(), returnEvents.count == 2,
              let original = armedFocus else {
            cancelFromEvent("original application or send authorization unavailable")
            return false
        }
        attemptActive = false
        sentOnEventThread = true
        lastSendReason = reason
        if !dryRun {
            for key in returnEvents {
                key.postToPid(original.processID)
            }
        }
        guard report else { return true }
        if dryRun { onSent?(reason) }
        else {
            let epoch = attemptEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                guard self.attemptEpoch == epoch else { return }
                self.onSent?(reason)
            }
        }
        return true
    }

    private func monitoringInterrupted(_ reason: String) {
        observedMonitoringGap = true
        pasteCapture = nil
        cancelFromEvent("input monitoring interrupted")
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

    func armAttempt(focus: FocusSnapshot, pastedText: String = "", authorize: @escaping () -> Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        authorizeSend = authorize
        self.pastedText = pastedText
        pasteBaseline = nil
        pendingDeparture = consumedPaste?.departed == true ? "original-pid" : nil
        if !originalIsFrontmost(focus) { pendingDeparture = "original-pid" }
        missedEvent.store(false, ordering: .releasing)
        settled = false
        sentOnEventThread = false
        returnEvents = [true, false].compactMap { down in
            guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: CGKeyCode(kVK_Return), keyDown: down) else { return nil }
            key.flags = []
            key.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            key.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(focus.processID))
            return key
        }
        attemptEpoch += 1
        attemptActive = true
        armedFocus = focus
        if dryRun, focus.sameTarget(as: simulatedFocus) { simulatedOriginalFocus = simulatedFocus }
        else if simulatedOriginalFocus?.sameTarget(as: focus) != true { simulatedOriginalFocus = focus }
        if dryRun, originalIsFrontmost(focus) { simulatedOriginalApplicationFocus = simulatedFocus }
        if !dryRun, let observer = focusObserver, let input = focus.input {
            let context = Unmanaged.passUnretained(self).toOpaque()
            Self.registerContentNotifications { notification in
                AXObserverAddNotification(observer, input, notification as CFString, context)
            }
        }
    }

    // AX notification support varies independently of usable text/selection
    // attributes. Registration is best effort; foreground polling is the backup.
    static func registerContentNotifications(_ register: (String) -> AXError) {
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            _ = register(notification)
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
        consumedPaste = nil
        pasteBaseline = nil
        pendingDeparture = nil
        if let focusObserver {
            CFRunLoopRemoveSource(eventRunLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        return outcome
    }

    func beginAttempt(recordID: String? = nil) -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        recoverMonitoringIfNeeded()
        guard available else { return .failure(InputMonitorError(reason: "input monitoring unavailable: \(monitoringState.unavailableReason ?? "unknown")")) }
        let result: Result<FocusSnapshot, InputMonitorError>
        if missedPasteCapture.exchange(false, ordering: .acquiringAndReleasing) { pasteCapture = nil }
        if let capture = pasteCapture, ProcessInfo.processInfo.systemUptime - capture.capturedAt > 10 { pasteCapture = nil }
        if let capture = pasteCapture, pasteRecordIDProvider == nil || (recordID != nil && capture.recordID == recordID) {
            pasteCapture = nil
            consumedPaste = capture
            result = .success(capture.focus)
        } else {
            consumedPaste = nil
            if requirePasteCapture || pasteCapture != nil { return .failure(InputMonitorError(reason: "awaiting Typeless paste")) }
            result = currentFocus()
        }
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
            guard !target.selectionAvailable || validSelectionRange(location: target.selectionStart, length: target.selectionLength) else {
                return .failure(InputMonitorError(reason: "invalid caret/selection range"))
            }
            return .success(target)
        }
        guard AXIsProcessTrusted(), NSRunningApplication(processIdentifier: target.processID)?.isTerminated == false else {
            return .failure(InputMonitorError(reason: "original application unavailable or accessibility not trusted"))
        }
        guard case .success(let identity) = inspectIdentity(target, deadline: deadline) else {
            return .failure(InputMonitorError(reason: "cannot inspect window/input focus"))
        }
        return inspectInput(identity, deadline: deadline)
    }

    // Read only identity. postToPid targets the application's current first
    // responder, so a confirmed focus change cannot safely send to the old one.
    private func inspectIdentity(_ target: FocusSnapshot, deadline: TimeInterval) -> Result<FocusSnapshot, InputMonitorError> {
        if dryRun {
            guard focusReadable else { return .failure(InputMonitorError(reason: "cannot inspect caret/focus")) }
            let current = originalIsFrontmost(target) ? simulatedFocus : (simulatedOriginalApplicationFocus ?? target)
            return .success(current)
        }
        let app = AXUIElementCreateApplication(target.processID)
        guard let windowValue = attribute(app, kAXFocusedWindowAttribute, deadline: deadline), CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              let inputValue = attribute(app, kAXFocusedUIElementAttribute, deadline: deadline), CFGetTypeID(inputValue) == AXUIElementGetTypeID() else {
            return .failure(InputMonitorError(reason: "cannot inspect window/input focus"))
        }
        return .success(FocusSnapshot(bundleID: target.bundleID, processID: target.processID,
            window: (windowValue as! AXUIElement), input: (inputValue as! AXUIElement)))
    }

    private func originalIdentityUnchanged(_ original: FocusSnapshot) -> Bool {
        if case .success(let current) = inspectIdentity(original, deadline: ProcessInfo.processInfo.systemUptime + 0.025),
           !original.sameTarget(as: current) {
            cancelFromEvent("original input focus changed before delivery")
            return false
        }
        return true
    }

    // Settlement and background notification reads use the captured input object,
    // never the application's newly focused element after the user leaves.
    private func inspectInput(_ target: FocusSnapshot, deadline: TimeInterval) -> Result<FocusSnapshot, InputMonitorError> {
        if dryRun { return inspectFocus(target, deadline: deadline) }
        guard let input = target.input, let text = attribute(input, kAXValueAttribute, deadline: deadline) as? String else {
            return .failure(InputMonitorError(reason: "cannot inspect original input content"))
        }
        var snapshot = target
        snapshot.text = text
        snapshot.selectionAvailable = false
        var range = CFRange()
        if let value = attribute(input, kAXSelectedTextRangeAttribute, deadline: deadline),
           CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &range),
           validSelectionRange(location: range.location, length: range.length) {
            snapshot.selectionAvailable = true
            snapshot.selectionStart = range.location
            snapshot.selectionLength = range.length
        }
        return .success(snapshot)
    }

    // Typeless may finish its paste during the existing 150 ms paste buffer.
    // Freeze content and selection after that buffer, never after user editing.
    func settleAttempt(testEvent: Bool = false) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !manualTestSettlement || testEvent else { return }
        guard attemptActive, let original = armedFocus else { return }
        let target = dryRun ? (simulatedOriginalFocus ?? original) : original
        guard case .success(let current) = inspectInput(target, deadline: ProcessInfo.processInfo.systemUptime + 0.025),
              original.sameTarget(as: current) else {
            cancelFromEvent("cannot settle original input"); return
        }
        guard originalIdentityUnchanged(original) else { return }
        let before = consumedPaste?.focus
        let reportsSelection = before?.selectionAvailable == true && current.selectionAvailable &&
            (before?.selectionStart != 0 || before?.selectionLength != 0 || current.selectionStart != 0 || current.selectionLength != 0)
        if let before, !pastedText.isEmpty {
            if PasteBaseline.settlementWasEdited(beforeText: before.text,
                insertionStart: reportsSelection ? before.selectionStart : nil,
                insertionLength: reportsSelection ? before.selectionLength : 0,
                afterText: current.text, pastedText: pastedText) {
                cancelFromEvent("original content edited during paste buffer")
                return
            }
            if reportsSelection {
                let (expectedCaret, overflow) = before.selectionStart.addingReportingOverflow(pastedText.utf16.count)
                if overflow || current.selectionStart != expectedCaret || current.selectionLength != 0 {
                    cancelFromEvent("original caret/selection changed during paste buffer")
                    return
                }
            }
        }
        pasteBaseline = PasteBaseline(beforeText: before?.text,
            insertionStart: reportsSelection ? before?.selectionStart : nil,
            insertionLength: reportsSelection ? before?.selectionLength ?? 0 : 0, afterText: current.text, pastedText: pastedText)
        armedFocus = current
        settled = true
        if let reason = pendingDeparture { pendingDeparture = nil; requestDeparture(reason) }
    }

    func validateAttempt(deadline: TimeInterval? = nil) -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        guard healthyForSend(), let original = armedFocus else {
            return .failure(InputMonitorError(reason: "attempt already consumed, cancelled or input inspection interrupted"))
        }
        guard settled, originalIsFrontmost(original) else { return .success(original) }
        let result = dryRun ? inspectFocus(simulatedFocus, deadline: .infinity)
            : inspectFocus(original, deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 0.025)
        // Only observed editing cancels. A transient AX read failure is not an edit.
        guard case .success(let current) = result else { return .success(original) }
        guard original.sameTarget(as: current) else {
            cancelFromEvent("original input focus changed before delivery")
            return .failure(InputMonitorError(reason: "original input focus changed before delivery"))
        }
        guard !contentWasEdited(current, baseline: original) else {
            cancelFromEvent("original content/caret/selection changed")
            return .failure(InputMonitorError(reason: "original content/caret/selection changed"))
        }
        return .success(current)
    }

    private func contentWasEdited(_ current: FocusSnapshot, baseline original: FocusSnapshot) -> Bool {
        let selectionChanged = original.selectionAvailable && current.selectionAvailable &&
            (original.selectionStart != current.selectionStart || original.selectionLength != current.selectionLength)
        return pasteBaseline?.matches(current.text) == false || selectionChanged
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
            // The timer performs health/authorization checks only. All content
            // and caret comparisons happen during foreground monitoring.
            let safe = epoch == attemptEpoch && sendNow(reason: "original-pid", report: false)
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
                    if monitor.settled { _ = monitor.validateAttempt() }
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
        guard attemptActive, let original = armedFocus, originalIsFrontmost(original) else { return }
        if !original.sameTarget(as: notified) {
            cancelFromEvent("original input focus changed before delivery")
            return
        }
        _ = validateAttempt()
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
            let type = json["type"] as? String
            if type == "typeless_paste" || (type == "keyboard" && json["key"] as? String == "v" &&
                ["typeless", "typeless-helper-verified"].contains(json["origin"] as? String ?? "")) { capturePaste() }
            if type == "settle", manualTestSettlement { settleAttempt(testEvent: true) }
            if type == "transition", json["kind"] as? String != "tab",
               let original = attemptActive ? armedFocus : pasteCapture?.focus,
               normalizeBundleID(json["app"] as? String ?? simulatedFocus.bundleID) == normalizeBundleID(original.bundleID) {
                handleMouseTarget(json["sameInput"] as? Bool == true ? .inside : .outside, hitPID: original.processID)
            }
            if type == "edit_notification", settled { _ = validateAttempt() }
            if type == "focus_notification", var notified = armedFocus {
                if let readable = json["focusReadable"] as? Bool { focusReadable = readable }
                if let window = json["window"] as? String { notified.windowToken = window }
                if let input = json["input"] as? String { notified.inputToken = input }
                handleFocusNotification(notified)
            }
            if type == "deactivate" {
                if let pid = armedFocus?.processID ?? pasteCapture?.focus.processID { applicationDeactivated(pid: pid) }
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
                if let value = json["processAlive"] as? Bool {
                    simulatedProcessAlive = value
                    if !value { cancelFromEvent("original application exited") }
                }
                if let value = json["accessibilityTrusted"] as? Bool {
                    simulatedAccessibilityTrusted = value
                    if !value { cancelFromEvent("accessibility permission lost") }
                }
                if let value = json["secureInput"] as? Bool { simulatedMonitoring.secureInputEnabled = value }
                if !available {
                    observedMonitoringGap = true
                    onKeyboard?("input monitoring unavailable")
                }

            }
            if type == "focus" || type == "state" || type == "mouse" || type == "unnotified_state" {
                let before = simulatedFocus
                if let app = json["app"] as? String { simulatedFocus.bundleID = app }
                if let window = json["window"] as? String { simulatedFocus.windowToken = window }
                if let input = json["input"] as? String { simulatedFocus.inputToken = input }
                if let caret = json["caret"] as? Int { simulatedFocus.selectionStart = caret }
                if let length = json["selectionLength"] as? Int { simulatedFocus.selectionLength = length }
                if let value = json["selectionAvailable"] as? Bool { simulatedFocus.selectionAvailable = value }
                if let text = json["text"] as? String { simulatedFocus.text = text }
                if let original = armedFocus {
                    if normalizeBundleID(simulatedFocus.bundleID) == normalizeBundleID(original.bundleID) {
                        simulatedOriginalApplicationFocus = simulatedFocus
                    } else if normalizeBundleID(before.bundleID) == normalizeBundleID(original.bundleID) {
                        simulatedOriginalApplicationFocus = before
                    }
                    if original.sameTarget(as: simulatedFocus) { simulatedOriginalFocus = simulatedFocus }
                    else if original.sameTarget(as: before) { simulatedOriginalFocus = before }
                    if normalizeBundleID(before.bundleID) == normalizeBundleID(original.bundleID),
                       normalizeBundleID(simulatedFocus.bundleID) != normalizeBundleID(original.bundleID) {
                        applicationDeactivated(pid: original.processID)
                    } else if originalIsFrontmost(original), !original.sameTarget(as: simulatedFocus) {
                        handleFocusNotification(simulatedFocus)
                    } else if settled && type != "unnotified_state" { _ = validateAttempt() }
                }
                if let capture = pasteCapture {
                    if normalizeBundleID(simulatedFocus.bundleID) == normalizeBundleID(capture.focus.bundleID) {
                        simulatedOriginalApplicationFocus = simulatedFocus
                    } else if normalizeBundleID(before.bundleID) == normalizeBundleID(capture.focus.bundleID) {
                        simulatedOriginalApplicationFocus = before
                    }
                    if capture.focus.sameTarget(as: simulatedFocus) { simulatedOriginalFocus = simulatedFocus }
                    else if capture.focus.sameTarget(as: before) {
                        simulatedOriginalFocus = before
                        pasteCapture?.departed = true
                    }
                }
            }
        }
    }
}
