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

    func sameWindow(as other: FocusSnapshot) -> Bool {
        guard normalizeBundleID(bundleID) == normalizeBundleID(other.bundleID), processID == other.processID,
              windowToken == other.windowToken else { return false }
        if let window, let otherWindow = other.window, !CFEqual(window, otherWindow) { return false }
        return (window == nil) == (other.window == nil)
    }

    func sameTarget(as other: FocusSnapshot) -> Bool {
        guard sameWindow(as: other), inputToken == other.inputToken else { return false }
        if let input, let otherInput = other.input, !CFEqual(input, otherInput) { return false }
        return (input == nil) == (other.input == nil)
    }

    func sameSelection(as other: FocusSnapshot) -> Bool {
        sameTarget(as: other) && selectionStart == other.selectionStart && selectionLength == other.selectionLength && text == other.text
    }
}

struct InputMonitorError: Error { let reason: String }
struct InputAttemptOutcome { let sentReason: String?; let cancellationReason: String? }

enum InputEventRoute {
    case process(pid_t)
    case tap(CGEventTapProxy?)
    case session
}

func markInputEvent(_ event: CGEvent, _ marker: Int64,
                            sourceFactory: (CGEvent) -> CGEventSource? = { CGEventSource(event: $0) }) {
    // Replacing the source updates metadata even after CoreGraphics cached a
    // previous userData value. Integer-field mutation alone can keep the old one.
    if let source = sourceFactory(event) ?? CGEventSource(stateID: .privateState) {
        source.userData = marker
        event.setSource(source)
    } else { event.setIntegerValueField(.eventSourceUserData, value: marker) }
}

// The input gate has its own lock so an AX/state-lock read cannot lose the
// second half of a held gesture. Once a mouse-down is held,
// every following input stays behind it until replay or a finite fail-open.
private final class InputClickOrder {
    struct Owner { var epoch: Int?; let generation: Int }
    enum Phase { case waiting, carrier, claimed, releasing }
    struct Held { let serial: Int64; var owner: Owner; let deadline: TimeInterval; var events: [CGEvent]; var phase: Phase }
    static let replayMarker: Int64 = 0x545950454C455353
    static let carrierPrefix: Int64 = 0x434C494300000000
    private let lock = NSRecursiveLock()
    private var nextSerial: Int64 = 0
    private var held: Held?
    private var failure: (Owner, String)?
    var scheduleReplay: ((@escaping () -> Void) -> Void)?
    var prepareReplay: ((CGEvent) -> Void)?
    static let limit = 256
    static func isCarrier(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) & ~0xFFFFFFFF == carrierPrefix
    }
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
    func failureReason(epoch: Int, generation: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let (owner, reason) = failure else { return nil }
        return owner.epoch == epoch || (generation > 0 && owner.generation == generation) ? reason : nil
    }
    func begin(_ event: CGEvent, owner: Owner, deadline: TimeInterval) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard held == nil, let copy = event.copy() else { return nil }
        nextSerial = (nextSerial + 1) & 0xFFFFFFFF
        if nextSerial == 0 { nextSerial = 1 }
        held = Held(serial: nextSerial, owner: owner, deadline: deadline, events: [copy], phase: .waiting)
        return nextSerial
    }
    func append(_ event: CGEvent, post: @escaping ([CGEvent]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard held != nil else { return false }
        if let current = held, current.events.count >= Self.limit {
            // A later physical callback proves the claimed-down callback has
            // returned. Drain before letting this next event through.
            if current.phase == .claimed { finish(current.serial, post: post) }
            else { drainRelease(current.serial, post: post) }
            return false
        }
        guard let copy = event.copy() else { release("cannot copy held input", post: post); return false }
        held!.events.append(copy)
        if held!.events.count >= Self.limit { release("held input queue limit exceeded", post: post) }
        return true
    }
    func adopt(epoch: Int, generation: Int, post: @escaping ([CGEvent]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let current = held else { return }
        if current.owner.epoch == nil, generation > 0, current.owner.generation == generation {
            held!.owner.epoch = epoch
        } else if current.owner.epoch != epoch { release("held input belongs to an ended attempt", post: post) }
    }
    func requestCarrier(epoch: Int, generation: Int, post: @escaping ([CGEvent]) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = held else { return false }
        guard current.owner.epoch == epoch, current.owner.generation == generation else { return true }
        guard current.phase == .waiting else { return true }
        held!.phase = .carrier
        postCarrier(serial: current.serial, post: post)
        return true
    }
    private func postCarrier(serial: Int64, post: @escaping ([CGEvent]) -> Void) {
        // A null carrier cannot click if the event tap disappears before ack.
        guard let event = CGEvent(source: nil) else { release("cannot create replay carrier", post: post); return }
        event.type = .null
        markInputEvent(event, Self.carrierPrefix | serial)
        post([event])
    }
    func retryCarrier(serial: Int64, post: @escaping ([CGEvent]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard held?.serial == serial, held?.phase == .carrier else { return }
        postCarrier(serial: serial, post: post)
    }
    func claim(_ event: CGEvent, now: TimeInterval, post: @escaping ([CGEvent]) -> Void,
               send: (Owner) -> Bool) -> (Int64, CGEvent)? {
        lock.lock(); defer { lock.unlock() }
        let serial = event.getIntegerValueField(.eventSourceUserData) & 0xFFFFFFFF
        guard let current = held, current.serial == serial, current.phase == .carrier else { return nil }
        guard now < current.deadline else { release("held input wait expired", post: post); return nil }
        // Claim before emission. Timeout/endAttempt can never replay this down twice.
        held!.phase = .claimed
        guard send(current.owner) else { held!.phase = .carrier; release("held input send cancelled", post: post); return nil }
        let first = current.events[0]
        prepare(first)
        return (serial, first)
    }
    func finish(_ serial: Int64, post: @escaping ([CGEvent]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let current = held, current.serial == serial, current.phase == .claimed else { return }
        held = nil
        let events = Array(current.events.dropFirst())
        for event in events { prepare(event) }
        if !events.isEmpty { post(events) }
    }
    func expire(now: TimeInterval, serial: Int64? = nil, post: @escaping ([CGEvent]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let current = held, serial == nil || current.serial == serial, now >= current.deadline else { return }
        release("held input wait expired", post: post)
    }
    func release(_ reason: String?, post: @escaping ([CGEvent]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let current = held else { return }
        // A claimed down is being returned by a callback. Only its event-thread
        // continuation may release the tail, after that callback has returned.
        guard current.phase != .claimed, current.phase != .releasing else { return }
        if let reason { failure = (current.owner, reason) }
        held!.phase = .releasing
        let drain = { [self] in drainRelease(current.serial, post: post) }
        if let scheduleReplay { scheduleReplay(drain) } else { drain() }
    }
    private func drainRelease(_ serial: Int64, post: @escaping ([CGEvent]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let current = held, current.serial == serial, current.phase == .releasing else { return }
        let events = current.events
        for event in events { prepare(event) }
        if !events.isEmpty { post(events) }
        held = nil
    }
    private func prepare(_ event: CGEvent) {
        if let prepareReplay { prepareReplay(event) }
        else { markInputEvent(event, Self.replayMarker) }
    }
}

struct InputObservationToken: Hashable { let observerID: UInt; let epoch: Int }

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
    private let settlementNow: () -> TimeInterval
    private let eventPoster: ((InputEventRoute, [CGEvent]) -> Void)?
    private let eventSourceFactory: (CGEvent) -> CGEventSource?
    private let clickOrder = InputClickOrder()
    private var callbackDeliveryRoute: InputEventRoute?
    private var firstCancellationReason: String?
    private let deferCancelReport: Bool
    private var eventOffset = 0
    // All attempt/tap state is shared with the dedicated event thread. Callbacks
    // consume the attempt synchronously; reporting to the main loop is asynchronous.
    private let stateLock = NSRecursiveLock()
    // A busy AX read must never hold up a physical input event. Only a missed
    // actionable mouse event or real monitoring gap invalidates an attempt.
    private let missedEvent = Atomic<Bool>(false)
    private let missedPasteCapture = Atomic<Bool>(false)
    private let publishedPasteGeneration = Atomic<Int>(0)
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
    private static let settlementTimeout: TimeInterval = 1
    private static let settlementRetryInterval: TimeInterval = 0.05
    private var settled = false
    private var settlementDeadline: TimeInterval = 0
    private var settlementRetryScheduled = false
    private var settlementWaitKind: String?
    private struct Departure {
        var reason: String
        var focusChanged: Bool
    }
    private struct PasteCapture {
        var generation: Int
        var focus: FocusSnapshot
        var recordID: String?
        var capturedAt: TimeInterval
        var departure: Departure?
    }
    private var pasteCapture: PasteCapture?
    private var consumedPaste: PasteCapture?
    private var pasteBaseline: PasteBaseline?
    private var pastedText = ""
    private var pendingDeparture: Departure?
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
    var preparedReturnTargetPIDs: [Int64] {
        stateLock.lock(); defer { stateLock.unlock() }
        return returnEvents.map { $0.getIntegerValueField(.eventTargetUnixProcessID) }
    }
    private static let eventMarker: Int64 = 0x545950454C455353
    private static let replayedPastePrefix: Int64 = 0x5459505000000000
    private struct ReplayPasteTicket {
        let epoch: Int
        let generation: Int
        let expiresAt: TimeInterval
    }
    private let replayTicketLock = NSLock()
    private var replayTickets: [Int64: ReplayPasteTicket] = [:]
    private var replayTicketSequence: Int64 = 0
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var focusObserver: AXObserver?
    private let publishedObserverID = Atomic<UInt>(0)
    private let publishedAttemptEpoch = Atomic<Int>(0)
    private let deferredAXLock = NSLock()
    private var deferredAttemptEvents: [InputObservationToken: Int] = [:]
    var currentObservationToken: InputObservationToken? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard attemptActive else { return nil }
        return InputObservationToken(observerID: publishedObserverID.load(ordering: .acquiring), epoch: attemptEpoch)
    }
    private var simulatedOriginalFocus: FocusSnapshot?
    private var simulatedOriginalApplicationFocus: FocusSnapshot?
    private var simulatedFocus: FocusSnapshot
    private var focusReadable = true
    private var identityReadable = true
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

    init(dryRun: Bool, environment: [String: String],
         settlementNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         eventPoster: ((InputEventRoute, [CGEvent]) -> Void)? = nil,
         eventSourceFactory: @escaping (CGEvent) -> CGEventSource? = { CGEventSource(event: $0) }) {
        self.dryRun = dryRun
        self.settlementNow = settlementNow
        self.eventPoster = eventPoster
        self.eventSourceFactory = eventSourceFactory
        deferCancelReport = dryRun && environment["TYPELESS_TEST_DEFER_CANCEL_REPORT"] == "1"
        requirePasteCapture = !dryRun || environment["TYPELESS_TEST_REQUIRE_PASTE"] == "1"
        manualTestSettlement = dryRun && environment["TYPELESS_TEST_MANUAL_SETTLE"] == "1"
        eventPath = dryRun ? environment["TYPELESS_TEST_EVENTS"] : nil
        simulatedFocus = FocusSnapshot(bundleID: environment["TYPELESS_FAKE_FRONT"] ?? "dry-run")
        if dryRun { publishedObserverID.store(1, ordering: .releasing) }
        if dryRun, let pid = environment["TYPELESS_TEST_TYPELESS_PID"].flatMap(Int32.init) {
            verifiedTypelessPIDs = [pid]
        }
        clickOrder.scheduleReplay = { [weak self] action in self?.afterTapCallback(action) }
        clickOrder.prepareReplay = { [weak self] event in self?.prepareReplayEvent(event) }
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
        let mask = [CGEventType.null, .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                guard let output = monitor.handleTapEvent(type, event, proxy: proxy) else { return nil }
                // CoreGraphics releases a replacement event after the callback.
                return output === event ? Unmanaged.passUnretained(event) : Unmanaged.passRetained(output)
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
        let reason = cancellationContext(reason)
        if firstCancellationReason == nil { firstCancellationReason = reason }
        attemptActive = false
        releaseHeldInput(reason)
        if dryRun && !deferCancelReport { onKeyboard?(reason) }
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

    private func cancellationContext(_ reason: String) -> String {
        guard let original = armedFocus, !reason.contains(" app=") else { return reason }
        return "\(reason) app=\(original.bundleID) pid=\(original.processID)"
    }

    func handleTapEvent(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy? = nil,
                        mouseTarget: InputTargetRelation? = nil) -> CGEvent? {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker & ~0xFFFFFFFF == Self.replayedPastePrefix {
            // Replayed Typeless paste belongs to the focus observed when it
            // actually leaves this tap, after the earlier held mouse-down.
            replayTicketLock.lock()
            let ticket = replayTickets.removeValue(forKey: marker)
            replayTicketLock.unlock()
            guard let ticket, ticket.expiresAt > settlementNow(),
                  ticket.generation == publishedPasteGeneration.load(ordering: .acquiring) else { return event }
            guard stateLock.try() else { missedPasteCapture.store(true, ordering: .releasing); return event }
            defer { stateLock.unlock() }
            // Ending the old attempt does not invalidate the user's next
            // queued paste. A newly armed epoch or newer paste does.
            guard ticket.epoch == attemptEpoch || (!attemptActive && attemptEpoch == ticket.epoch + 1) else { return event }
            capturePaste()
            return event
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return event }
        if InputClickOrder.isCarrier(event) {
            guard stateLock.try() else {
                let serial = event.getIntegerValueField(.eventSourceUserData) & 0xFFFFFFFF
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                    self?.clickOrder.retryCarrier(serial: serial) { self?.postEvents($0, route: .session) }
                }
                return nil
            }
            defer { stateLock.unlock() }
            let claimed = clickOrder.claim(event, now: settlementNow(), post: { self.postEvents($0, route: .session) }) { owner in
                guard owner.epoch == attemptEpoch, owner.generation == currentPasteGeneration,
                      let original = armedFocus else {
                    cancelFromEvent("held click belongs to an ended attempt")
                    return false
                }
                let frontmost = originalIsFrontmost(original)
                let focusChanged = !frontmost || originalClickFocusRelation(original) == .outside
                callbackDeliveryRoute = frontmost ? .tap(proxy) : .process(original.processID)
                defer { callbackDeliveryRoute = nil }
                return requestDeparture(frontmost ? "before-focus-change" : "original-pid", focusChanged: focusChanged)
            }
            guard let (serial, down) = claimed else { return nil }
            afterTapCallback { [self] in clickOrder.finish(serial) { self.postEvents($0, route: .session) } }
            return down
        }
        let interrupted = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        if interrupted { releaseHeldInput("input monitoring interrupted") }
        else if clickOrder.append(event, post: { self.postEvents($0, route: .session) }) {
            if isVerifiedPaste(type, event) { releaseHeldInput("new Typeless paste while click was held") }
            return nil
        }
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) else {
            handleEvent(type, event)
            return event
        }
        guard stateLock.try() else { missedEvent.store(true, ordering: .releasing); return event }
        defer { stateLock.unlock() }
        guard let original = attemptActive ? armedFocus : pasteCapture?.focus,
              originalIsFrontmost(original) else { return event }
        let relation: InputTargetRelation
        if let mouseTarget { relation = mouseTarget }
        else {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.025
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.005)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(event.location.x), Float(event.location.y), &hit) == .success,
                  let hit else { return event }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid == original.processID else { return event }
            relation = original.input.map { classifyInputTarget(hit, $0, deadline: deadline) } ?? .unknown
        }
        guard relation == .outside else { return event }
        if attemptActive && settled {
            let focusChanged = originalClickFocusRelation(original) == .outside
            callbackDeliveryRoute = .tap(proxy)
            defer { callbackDeliveryRoute = nil }
            requestDeparture("before-focus-change", focusChanged: focusChanged)
            return event
        }
        let now = settlementNow()
        let deadline = attemptActive ? min(settlementDeadline, now + Self.settlementTimeout) : now + Self.settlementTimeout
        let owner = InputClickOrder.Owner(epoch: attemptActive ? attemptEpoch : nil, generation: currentPasteGeneration)
        guard let serial = clickOrder.begin(event, owner: owner, deadline: deadline) else {
            if attemptActive { cancelFromEvent("cannot hold outside click") }
            return event
        }
        if attemptActive { pendingDeparture = Departure(reason: "before-focus-change", focusChanged: pendingDeparture?.focusChanged == true) }
        else {
            let blurred = pasteCapture?.departure?.focusChanged == true
            pasteCapture?.departure = Departure(reason: "before-focus-change", focusChanged: blurred)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline - now)) { [weak self] in
            guard let self else { return }
            self.clickOrder.expire(now: self.settlementNow(), serial: serial) { self.postEvents($0, route: .session) }
        }
        return nil
    }

    private var currentPasteGeneration: Int { consumedPaste?.generation ?? pasteCapture?.generation ?? 0 }
    private func originalClickFocusRelation(_ original: FocusSnapshot) -> InputTargetRelation {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
        guard case .success(let focused) = inspectIdentity(original, deadline: deadline) else { return .unknown }
        guard original.sameWindow(as: focused) else { return .outside }
        return focusedInputRelation(original: original, focused: focused, deadline: deadline)
    }
    func isVerifiedPaste(_ type: CGEventType, _ event: CGEvent) -> Bool {
        type == .keyDown && event.flags.contains(.maskCommand) &&
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V) &&
            verifiedTypelessPIDs.contains(pid_t(event.getIntegerValueField(.eventSourceUnixProcessID)))
    }
    private func afterTapCallback(_ action: @escaping () -> Void) {
        if dryRun { DispatchQueue.main.async(execute: action) }
        else if let eventRunLoop {
            CFRunLoopPerformBlock(eventRunLoop, CFRunLoopMode.commonModes.rawValue, action)
            CFRunLoopWakeUp(eventRunLoop)
        }
    }
    private func releaseHeldInput(_ reason: String) {
        clickOrder.release(reason) { self.postEvents($0, route: .session) }
    }
    func checkHeldInputTimeout() {
        clickOrder.expire(now: settlementNow()) { self.postEvents($0, route: .session) }
    }

    private func prepareReplayEvent(_ event: CGEvent) {
        // Decide the final marker before changing source metadata. A source
        // copied from another process's private source can be unavailable.
        var marker = Self.eventMarker
        if isVerifiedPaste(event.type, event) {
            let ticket = ReplayPasteTicket(epoch: publishedAttemptEpoch.load(ordering: .acquiring),
                generation: publishedPasteGeneration.load(ordering: .acquiring),
                expiresAt: settlementNow() + 2)
            replayTicketLock.lock()
            replayTickets = replayTickets.filter { $0.value.expiresAt > settlementNow() }
            if replayTickets.count < InputClickOrder.limit {
                replayTicketSequence = (replayTicketSequence + 1) & 0xFFFFFFFF
                if replayTicketSequence == 0 { replayTicketSequence = 1 }
                marker = Self.replayedPastePrefix | replayTicketSequence
                replayTickets[marker] = ticket
            }
            replayTicketLock.unlock()
        }
        markInputEvent(event, marker, sourceFactory: eventSourceFactory)
    }

    func handleEvent(_ type: CGEventType, _ event: CGEvent, mouseTarget: InputTargetRelation? = nil) {
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
        if let mouseTarget { handleMouseTarget(mouseTarget, hitPID: original.processID); return }
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
        } else {
            let focusChanged = pasteCapture?.departure?.focusChanged == true
            pasteCapture?.departure = Departure(reason: "original-pid", focusChanged: focusChanged)
        }
    }

    // A common ancestor above two separate branches proves separation without
    // reading ancestors beyond it. Advance both walks so a deep web hierarchy
    // cannot consume the entire AX budget before inspecting the original side.
    static func classifyInputTarget<Element>(hit: Element, original: Element,
            equal: (Element, Element) -> Bool, parentStep: (Element) -> InputParentStep<Element>,
            maximumDepth: Int = 24) -> InputTargetRelation {
        if equal(hit, original) { return .inside }
        var hitPath: [Element] = [], originalPath: [Element] = []
        var hitNode: Element? = hit, originalNode: Element? = original
        var hitComplete = false, originalComplete = false
        for _ in 0..<maximumDepth {
            if let node = hitNode {
                if hitPath.contains(where: { equal($0, node) }) { hitNode = nil }
                else { hitPath.append(node) }
            }
            if let node = originalNode {
                if originalPath.contains(where: { equal($0, node) }) { originalNode = nil }
                else { originalPath.append(node) }
            }
            if hitPath.contains(where: { equal($0, original) }) || originalPath.contains(where: { equal($0, hit) }) { return .inside }
            if hitPath.contains(where: { left in originalPath.contains(where: { equal(left, $0) }) }) { return .outside }
            if let node = hitNode {
                switch parentStep(node) {
                case .parent(let parent): hitNode = parent
                case .boundary: hitNode = nil; hitComplete = true
                case .unavailable: hitNode = nil
                }
            }
            if let node = originalNode {
                switch parentStep(node) {
                case .parent(let parent): originalNode = parent
                case .boundary: originalNode = nil; originalComplete = true
                case .unavailable: originalNode = nil
                }
            }
            if hitNode == nil && originalNode == nil { break }
        }
        return hitComplete && originalComplete ? .outside : .unknown
    }

    private func classifyInputTarget(_ hit: AXUIElement, _ original: AXUIElement,
                                     deadline: TimeInterval) -> InputTargetRelation {
        // An application-level hit can contain the original window even when
        // the hit test omits every descendant. It never proves an outside click.
        if attribute(hit, kAXRoleAttribute, deadline: deadline) as? String == kAXApplicationRole { return .unknown }
        return Self.classifyInputTarget(hit: hit, original: original, equal: { CFEqual($0, $1) }, parentStep: { element in
            self.inputParentStep(element, deadline: deadline)
        })
    }

    private func inputParentStep(_ element: AXUIElement, deadline: TimeInterval) -> InputParentStep<AXUIElement> {
        guard let role = attribute(element, kAXRoleAttribute, deadline: deadline) as? String else { return .unavailable }
        if [kAXWindowRole, kAXApplicationRole].contains(role) { return .boundary }
        guard let parent = attribute(element, kAXParentAttribute, deadline: deadline),
              CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unavailable }
        return .parent(parent as! AXUIElement)
    }

    static func classifyFocusedInputTarget<Element>(focused: Element, original: Element,
            equal: (Element, Element) -> Bool, parentStep: (Element) -> InputParentStep<Element>) -> InputTargetRelation {
        if equal(focused, original) { return .inside }
        // A focus notification explicitly naming a window/application differs
        // from a coarse mouse hit that only identifies a containing window.
        if case .boundary = parentStep(focused) { return .outside }
        return classifyInputTarget(hit: focused, original: original, equal: equal, parentStep: parentStep)
    }

    static func focusHasDeparted(original: FocusSnapshot, focused: FocusSnapshot,
                                 inputRelation: InputTargetRelation) -> Bool {
        if original.sameTarget(as: focused) { return false }
        return !original.sameWindow(as: focused) || inputRelation == .outside
    }

    private func focusHasDeparted(original: FocusSnapshot, focused: FocusSnapshot, deadline: TimeInterval) -> Bool {
        Self.focusHasDeparted(original: original, focused: focused,
            inputRelation: focusedInputRelation(original: original, focused: focused, deadline: deadline))
    }

    private func focusedInputRelation(original: FocusSnapshot, focused: FocusSnapshot, deadline: TimeInterval) -> InputTargetRelation {
        if original.sameTarget(as: focused) { return .inside }
        guard original.sameWindow(as: focused) else { return .outside }
        // Distinct dry-run input tokens model separate controls. Native inputs
        // need a completed ancestry walk; an unreadable parent is inconclusive.
        var relation: InputTargetRelation = dryRun ? .outside : .unknown
        if !dryRun, original.sameWindow(as: focused), let input = focused.input, let originalInput = original.input {
            relation = Self.classifyFocusedInputTarget(focused: input, original: originalInput,
                equal: { CFEqual($0, $1) }, parentStep: { self.inputParentStep($0, deadline: deadline) })
        }
        return relation
    }

    private func originalInputIsFocused(_ original: FocusSnapshot, deadline: TimeInterval) -> Bool {
        guard originalIsFrontmost(original),
              case .success(let focused) = inspectIdentity(original, deadline: deadline) else { return false }
        return focusedInputRelation(original: original, focused: focused, deadline: deadline) == .inside
    }

    private func capturePaste() {
        releaseHeldInput("new Typeless paste")
        let generation = publishedPasteGeneration.load(ordering: .acquiring) &+ 1
        publishedPasteGeneration.store(generation, ordering: .releasing)
        missedPasteCapture.store(false, ordering: .releasing)
        pasteCapture = nil
        guard available, case .success(let snapshot) = currentFocus() else { return }
        pasteCapture = PasteCapture(generation: generation, focus: snapshot,
            recordID: pasteRecordIDProvider?(), capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    private func originalIsFrontmost(_ original: FocusSnapshot) -> Bool {
        if dryRun { return normalizeBundleID(simulatedFocus.bundleID) == normalizeBundleID(original.bundleID) }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == original.processID
    }

    func applicationDeactivated(pid: pid_t) {
        let token = InputObservationToken(observerID: publishedObserverID.load(ordering: .acquiring),
            epoch: publishedAttemptEpoch.load(ordering: .acquiring))
        let captureGeneration = publishedPasteGeneration.load(ordering: .acquiring)
        guard stateLock.try() else {
            deferAttemptEvent(token: token) { [self] in
                processApplicationDeactivation(pid: pid, epoch: token.epoch, captureGeneration: captureGeneration)
            }
            return
        }
        defer { stateLock.unlock() }
        processApplicationDeactivation(pid: pid, epoch: token.epoch, captureGeneration: captureGeneration)
    }

    private func processApplicationDeactivation(pid: pid_t, epoch: Int, captureGeneration: Int) {
        // A pre-arm departure still belongs to its capture after begin/arm has
        // changed attempt epoch. An older capture cannot mark a newer one left.
        if pasteCapture?.generation == captureGeneration, pasteCapture?.focus.processID == pid {
            pasteCapture?.departure = Departure(reason: "original-pid", focusChanged: true)
        }
        let consumedMatch = consumedPaste?.generation == captureGeneration && consumedPaste?.focus.processID == pid
        guard epoch == attemptEpoch || consumedMatch else { return }
        if consumedMatch { consumedPaste?.departure = Departure(reason: "original-pid", focusChanged: true) }
        guard attemptActive, armedFocus?.processID == pid else { return }
        requestDeparture("original-pid", focusChanged: true)
    }

    private func applicationTerminated(pid: pid_t) {
        guard stateLock.try() else { missedEvent.store(true, ordering: .releasing); return }
        defer { stateLock.unlock() }
        if pasteCapture?.focus.processID == pid { pasteCapture = nil }
        if armedFocus?.processID == pid { cancelFromEvent("original application exited") }
    }

    @discardableResult
    private func requestDeparture(_ reason: String, focusChanged: Bool = false) -> Bool {
        guard attemptActive else { return false }
        guard settled else {
            pendingDeparture = Departure(reason: reason,
                focusChanged: focusChanged || pendingDeparture?.focusChanged == true)
            return false
        }
        // An edit can precede its queued AX notification or foreground poll.
        // Take one final snapshot of the captured input object at departure;
        // subsequent background activity is never polled for content changes.
        if let original = armedFocus {
            // A focus notification/deactivation already proves blur, even when
            // AXFocusedUIElement briefly keeps returning the previous input.
            let compareSelection = !focusChanged && originalInputIsFocused(original, deadline: ProcessInfo.processInfo.systemUptime + 0.025)
            let target = dryRun ? (simulatedOriginalFocus ?? original) : original
            if case .success(let current) = inspectInput(target, deadline: ProcessInfo.processInfo.systemUptime + 0.025),
               let reason = contentEditReason(current, baseline: original, compareSelection: compareSelection) {
                cancelFromEvent(reason)
                return false
            }
        }
        return sendNow(reason: reason)
    }

    private func healthyForSend() -> Bool {
        if let reason = clickOrder.failureReason(epoch: attemptEpoch, generation: currentPasteGeneration) {
            cancelFromEvent(reason)
            return false
        }
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
        if callbackDeliveryRoute == nil,
           clickOrder.requestCarrier(epoch: attemptEpoch, generation: currentPasteGeneration,
               post: { self.postEvents($0, route: .session) }) { return false }
        attemptActive = false
        sentOnEventThread = true
        lastSendReason = reason
        postEvents(returnEvents, route: callbackDeliveryRoute ?? .process(original.processID))
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

    private func postEvents(_ events: [CGEvent], route: InputEventRoute) {
        if let eventPoster { eventPoster(route, events); return }
        guard !dryRun else { return }
        for event in events {
            switch route {
            case .process(let pid): event.postToPid(pid)
            case .tap(let proxy): event.tapPostEvent(proxy)
            case .session: event.post(tap: .cgSessionEventTap)
            }
        }
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
        firstCancellationReason = nil
        authorizeSend = authorize
        self.pastedText = pastedText
        pasteBaseline = nil
        pendingDeparture = consumedPaste?.departure
        if !originalIsFrontmost(focus) { pendingDeparture = Departure(reason: "original-pid", focusChanged: true) }
        missedEvent.store(false, ordering: .releasing)
        settled = false
        settlementDeadline = settlementNow() + Self.settlementTimeout
        settlementRetryScheduled = false
        settlementWaitKind = nil
        sentOnEventThread = false
        returnEvents = [true, false].compactMap { down in
            guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: CGKeyCode(kVK_Return), keyDown: down) else { return nil }
            key.flags = []
            key.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            key.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(focus.processID))
            return key
        }
        attemptEpoch += 1
        publishedAttemptEpoch.store(attemptEpoch, ordering: .releasing)
        attemptActive = true
        armedFocus = focus
        clickOrder.adopt(epoch: attemptEpoch, generation: currentPasteGeneration) { self.postEvents($0, route: .session) }
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
        endAttemptOutcome().sentReason
    }

    @discardableResult
    func endAttemptOutcome() -> InputAttemptOutcome {
        stateLock.lock(); defer { stateLock.unlock() }
        // Cancellation and observing a completed send are one atomic operation.
        // A queued timer cannot post between the caller's decision and disarm.
        let outcome = InputAttemptOutcome(sentReason: sentOnEventThread ? lastSendReason : nil,
            cancellationReason: firstCancellationReason)
        releaseHeldInput("attempt ended")
        authorizeSend = nil
        sentOnEventThread = false
        returnEvents = []
        attemptEpoch += 1
        publishedAttemptEpoch.store(attemptEpoch, ordering: .releasing)
        attemptActive = false
        armedFocus = nil
        consumedPaste = nil
        pasteBaseline = nil
        pendingDeparture = nil
        settlementDeadline = 0
        settlementRetryScheduled = false
        settlementWaitKind = nil
        firstCancellationReason = nil
        if let focusObserver {
            CFRunLoopRemoveSource(eventRunLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        if !dryRun { publishedObserverID.store(0, ordering: .releasing) }
        return outcome
    }

    func beginAttempt(recordID: String? = nil) -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        recoverMonitoringIfNeeded()
        guard available else { return .failure(InputMonitorError(reason: "input monitoring unavailable: \(monitoringState.unavailableReason ?? "unknown")")) }
        let result: Result<FocusSnapshot, InputMonitorError>
        if missedPasteCapture.exchange(false, ordering: .acquiringAndReleasing) { pasteCapture = nil }
        if let capture = pasteCapture, ProcessInfo.processInfo.systemUptime - capture.capturedAt > 10 { pasteCapture = nil }
        if let capture = pasteCapture,
           clickOrder.failureReason(epoch: attemptEpoch, generation: capture.generation) != nil { pasteCapture = nil }
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

    // Read identity independently from content. A focus transition is a
    // departure; content checks continue to use the captured original input.
    private func inspectIdentity(_ target: FocusSnapshot, deadline: TimeInterval) -> Result<FocusSnapshot, InputMonitorError> {
        if dryRun {
            guard identityReadable else { return .failure(InputMonitorError(reason: "cannot inspect input identity")) }
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

    // The first sample follows the 150 ms paste buffer. AX values can remain
    // cached after visible insertion, so unobserved text gets bounded retries.
    // Every usable sample still passes the original content/caret edit checks.
    func settleAttempt(testEvent: Bool = false) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !manualTestSettlement || testEvent else { return }
        guard attemptActive, !settled, let original = armedFocus else { return }
        if settlementWaitKind != nil, settlementNow() >= settlementDeadline {
            expireUnobservedPaste()
            return
        }
        let target = dryRun ? (simulatedOriginalFocus ?? original) : original
        guard case .success(let current) = inspectInput(target, deadline: ProcessInfo.processInfo.systemUptime + 0.025),
              original.sameTarget(as: current) else {
            cancelFromEvent("cannot settle original input"); return
        }
        if consumedPaste != nil, !pastedText.isEmpty, current.text.isEmpty {
            waitForPastedText(kind: "empty")
            return
        }
        let before = consumedPaste?.focus
        let reportsSelection = before?.selectionAvailable == true && current.selectionAvailable &&
            (before?.selectionStart != 0 || before?.selectionLength != 0 || current.selectionStart != 0 || current.selectionLength != 0)
        let compareSelection = pendingDeparture?.focusChanged != true &&
            originalInputIsFocused(original, deadline: ProcessInfo.processInfo.systemUptime + 0.025)
        if let before, !pastedText.isEmpty {
            if before.text == current.text {
                let text = before.text as NSString
                let (expectedCaret, overflow) = before.selectionStart.addingReportingOverflow(pastedText.utf16.count)
                let trustedSameTextReplacement = before.selectionAvailable && current.selectionAvailable &&
                    before.selectionStart >= 0 && before.selectionLength > 0 &&
                    before.selectionStart <= text.length && before.selectionLength <= text.length - before.selectionStart &&
                    text.substring(with: NSRange(location: before.selectionStart, length: before.selectionLength)) == pastedText &&
                    !overflow && current.selectionStart == expectedCaret && current.selectionLength == 0
                guard trustedSameTextReplacement else {
                    waitForPastedText(kind: "unchanged")
                    return
                }
            }
            guard PasteBaseline.hasPastedTextEvidence(in: current.text, pastedText: pastedText) else {
                waitForPastedText(kind: "not_observed")
                return
            }
            if PasteBaseline.settlementWasEdited(beforeText: before.text,
                insertionStart: reportsSelection ? before.selectionStart : nil,
                insertionLength: reportsSelection ? before.selectionLength : 0,
                afterText: current.text, pastedText: pastedText) {
                cancelFromEvent("original content edited during paste buffer kind=content beforeUTF16=\(before.text.utf16.count) afterUTF16=\(current.text.utf16.count) pasteUTF16=\(pastedText.utf16.count)")
                return
            }
            if reportsSelection && compareSelection {
                let (expectedCaret, overflow) = before.selectionStart.addingReportingOverflow(pastedText.utf16.count)
                if overflow || current.selectionStart != expectedCaret || current.selectionLength != 0 {
                    cancelFromEvent("original caret/selection changed during paste buffer kind=\(current.selectionLength != 0 ? "selection" : "caret") expected=\(expectedCaret) actual=\(current.selectionStart) length=\(current.selectionLength)")
                    return
                }
            }
        }
        pasteBaseline = PasteBaseline(beforeText: before?.text,
            insertionStart: reportsSelection ? before?.selectionStart : nil,
            insertionLength: reportsSelection ? before?.selectionLength ?? 0 : 0, afterText: current.text, pastedText: pastedText)
        armedFocus = current
        settled = true
        settlementRetryScheduled = false
        settlementWaitKind = nil
        if let departure = pendingDeparture {
            pendingDeparture = nil
            requestDeparture(departure.reason, focusChanged: departure.focusChanged)
        }
        else {
            // Focus may have left between paste capture and observer setup.
            // Settle the captured input first, then detect that departure once.
            _ = validateAttempt()
        }
    }

    private func waitForPastedText(kind: String) {
        settlementWaitKind = kind
        let remaining = settlementDeadline - settlementNow()
        guard remaining > 0 else { expireUnobservedPaste(); return }
        // Manual settlement is a deterministic unit-test boundary. Production
        // retries the saved input object; it never replaces snapshot A or target.
        guard !manualTestSettlement, !settlementRetryScheduled else { return }
        settlementRetryScheduled = true
        let epoch = attemptEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + min(Self.settlementRetryInterval, remaining)) { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            guard self.attemptEpoch == epoch, self.attemptActive, !self.settled else { return }
            self.settlementRetryScheduled = false
            self.settleAttempt()
        }
    }

    private func expireUnobservedPaste() {
        cancelFromEvent("no pasted text observed in original input (kind=\(settlementWaitKind ?? "unsettled"), timeout)")
    }

    func validateAttempt(deadline: TimeInterval? = nil) -> Result<FocusSnapshot, InputMonitorError> {
        stateLock.lock(); defer { stateLock.unlock() }
        guard healthyForSend(), let original = armedFocus else {
            return .failure(InputMonitorError(reason: firstCancellationReason ?? "attempt already consumed, cancelled or input inspection interrupted"))
        }
        guard settled, originalIsFrontmost(original) else { return .success(original) }
        var compareSelection = false
        if case .success(let identity) = inspectIdentity(original, deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 0.025) {
            let relation = focusedInputRelation(original: original, focused: identity, deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 0.025)
            if Self.focusHasDeparted(original: original, focused: identity, inputRelation: relation) {
                requestDeparture("original-pid", focusChanged: true)
                return .success(original)
            }
            compareSelection = relation == .inside
        }
        // Identity can be unreadable while the captured input still exposes its
        // content. Continue checking that original object instead of treating
        // an unreadable current focus as either an edit or a skipped comparison.
        let result = inspectInput(dryRun ? (simulatedOriginalFocus ?? original) : original,
            deadline: deadline ?? ProcessInfo.processInfo.systemUptime + 0.025)
        // A text read may fail independently of the focused input's identity.
        // Unknown text is not proof that the protected region was edited.
        guard case .success(let current) = result else { return .success(original) }
        if let reason = contentEditReason(current, baseline: original, compareSelection: compareSelection) {
            let contextualReason = cancellationContext(reason)
            cancelFromEvent(contextualReason)
            return .failure(InputMonitorError(reason: contextualReason))
        }
        return .success(current)
    }

    private func contentEditReason(_ current: FocusSnapshot, baseline original: FocusSnapshot, compareSelection: Bool) -> String? {
        if pasteBaseline?.matches(current.text) == false {
            return "original content/caret/selection changed kind=content beforeUTF16=\(original.text.utf16.count) afterUTF16=\(current.text.utf16.count)"
        }
        guard compareSelection, original.selectionAvailable, current.selectionAvailable else { return nil }
        if original.selectionStart != current.selectionStart {
            return "original content/caret/selection changed kind=caret before=\(original.selectionStart) after=\(current.selectionStart)"
        }
        if original.selectionLength != current.selectionLength {
            return "original content/caret/selection changed kind=selection before=\(original.selectionLength) after=\(current.selectionLength)"
        }
        return nil
    }

    func deliver(completion: @escaping (Bool) -> Void) {
        stateLock.lock()
        let epoch = attemptEpoch
        stateLock.unlock()
        scheduleDelivery(epoch: epoch, completion: completion)
    }

    private func scheduleDelivery(epoch: Int, completion: @escaping (Bool) -> Void) {
        let operation = { [self] in performDelivery(epoch: epoch, completion: completion) }
        if dryRun { operation() }
        else if let eventRunLoop {
            CFRunLoopPerformBlock(eventRunLoop, CFRunLoopMode.commonModes.rawValue, operation)
            CFRunLoopWakeUp(eventRunLoop)
        } else { completion(false) }
    }

    func performDelivery(epoch: Int, completion: @escaping (Bool) -> Void) {
        guard stateLock.try() else {
            // Contention with an AX read is not cancellation. Retry the same
            // epoch after a short main-queue backoff; the eventual epoch/active
            // checks prevent an ended attempt from reviving or affecting a new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in
                scheduleDelivery(epoch: epoch, completion: completion)
            }
            return
        }
        defer { stateLock.unlock() }
        let token = InputObservationToken(observerID: publishedObserverID.load(ordering: .acquiring), epoch: epoch)
        deferredAXLock.lock()
        let awaitingNotification = (deferredAttemptEvents[token] ?? 0) > 0
        deferredAXLock.unlock()
        if epoch == attemptEpoch && awaitingNotification {
            // The notification/departure handler was queued before this block.
            // Process it before retrying the timer; the timer itself never reads
            // AX text or selection.
            DispatchQueue.main.async { [self] in scheduleDelivery(epoch: epoch, completion: completion) }
            return
        }
        if epoch == attemptEpoch, attemptActive, !settled {
            // A short send delay may expire before an application's AX value
            // reflects the paste. Wait for settlement without rereading content
            // on the delivery path, and retain the same finite settlement budget.
            if settlementNow() >= settlementDeadline {
                expireUnobservedPaste()
                DispatchQueue.main.async { completion(false) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settlementRetryInterval) { [self] in
                    scheduleDelivery(epoch: epoch, completion: completion)
                }
            }
            return
        }
        if epoch == attemptEpoch, attemptActive, clickOrder.isHolding {
            _ = sendNow(reason: "before-focus-change")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settlementRetryInterval) { [self] in
                scheduleDelivery(epoch: epoch, completion: completion)
            }
            return
        }
        let safe = epoch == attemptEpoch && sendNow(reason: "original-pid", report: false)
        DispatchQueue.main.async { completion(safe) }
    }

    private func observeFocus(pid: pid_t) -> Bool {
        if let focusObserver {
            CFRunLoopRemoveSource(eventRunLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        focusObserver = nil
        publishedObserverID.store(0, ordering: .releasing)
        var observer: AXObserver?
        guard AXObserverCreate(pid, { observer, element, notification, context in
            if let context {
                let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                let token = InputObservationToken(observerID: UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque()),
                    epoch: monitor.publishedAttemptEpoch.load(ordering: .acquiring))
                monitor.handleAXNotification(notification as String, token: token, element: element)
            }
        }, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
            guard AXObserverAddNotification(observer, app, notification as CFString, context) == .success else { return false }
        }
        focusObserver = observer
        publishedObserverID.store(UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque()), ordering: .releasing)
        CFRunLoopAddSource(eventRunLoop, AXObserverGetRunLoopSource(observer), .commonModes)
        return true
    }

    // Shared by the real AX callback and unit harness; the token binds callbacks
    // to both the installed observer and the attempt that was active on arrival.
    func handleAXNotification(_ notification: String, token: InputObservationToken, element: AXUIElement? = nil) {
        guard token.epoch == publishedAttemptEpoch.load(ordering: .acquiring),
              token.observerID == publishedObserverID.load(ordering: .acquiring) else { return }
        guard stateLock.try() else {
            if [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification].contains(notification) {
                // Content and focus notifications describe state to observe,
                // rather than a lost physical event. Preserve their token and
                // payload until the state lock becomes available.
                deferAttemptEvent(token: token) { [self] in
                    processAXNotification(notification, token: token, element: element)
                }
            }
            return
        }
        defer { stateLock.unlock() }
        processAXNotification(notification, token: token, element: element)
    }

    private func deferAttemptEvent(token: InputObservationToken, action: @escaping () -> Void) {
        deferredAXLock.lock()
        deferredAttemptEvents[token, default: 0] += 1
        DispatchQueue.main.async { [self] in
            stateLock.lock(); defer { stateLock.unlock() }
            action()
            deferredAXLock.lock()
            if let count = deferredAttemptEvents[token], count > 1 {
                deferredAttemptEvents[token] = count - 1
            } else { deferredAttemptEvents.removeValue(forKey: token) }
            deferredAXLock.unlock()
        }
        deferredAXLock.unlock()
    }

    private func processAXNotification(_ notification: String, token: InputObservationToken, element: AXUIElement?) {
        guard token.epoch == attemptEpoch, token.observerID == publishedObserverID.load(ordering: .acquiring),
              attemptActive, let original = armedFocus else { return }
        if [kAXValueChangedNotification, kAXSelectedTextChangedNotification].contains(notification) {
            if settled { _ = validateAttempt() }
            return
        }
        guard let element else { return }
        var notified = original
        if notification == kAXFocusedUIElementChangedNotification { notified.input = element }
        else { notified.window = element }
        handleFocusNotification(notified)
    }

    private func handleFocusNotification(_ notified: FocusSnapshot) {
        guard attemptActive, let original = armedFocus, originalIsFrontmost(original) else { return }
        if focusHasDeparted(original: original, focused: notified, deadline: ProcessInfo.processInfo.systemUptime + 0.025) {
            requestDeparture("original-pid", focusChanged: true)
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
                if let value = json["identityReadable"] as? Bool { identityReadable = value }
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
                if let value = json["pid"] as? Int, let pid = pid_t(exactly: value) { simulatedFocus.processID = pid }
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
                    } else if type != "unnotified_state", originalIsFrontmost(original), !original.sameTarget(as: simulatedFocus) {
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
                        if type != "unnotified_state" {
                            pasteCapture?.departure = Departure(reason: "original-pid", focusChanged: true)
                        }
                    }
                }
            }
        }
    }
}
