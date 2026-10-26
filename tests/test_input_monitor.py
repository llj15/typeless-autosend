"""Pure monitor unit harness. Dry-run never posts events or opens applications."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

class InputMonitorRules(unittest.TestCase):
    def test_leave_to_send_rules(self):
        with tempfile.TemporaryDirectory(prefix="autosend-monitor-unit-") as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text(r'''import Foundation
import ApplicationServices

let events = CommandLine.arguments[1]
let app = "com.example.editor"
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func event(_ monitor: InputMonitor, _ type: String, _ fields: [String: Any] = [:]) {
    let data = try! JSONSerialization.data(withJSONObject: fields.merging(["type": type]) { _, new in new })
    let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: events))
    try! handle.seekToEnd(); try! handle.write(contentsOf: data + Data([10])); try! handle.close()
    monitor.poll()
}
final class LogicalClock { var now: TimeInterval = 0 }
func make(requirePaste: Bool = false, manualSettle: Bool = false,
          now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> InputMonitor {
    try! Data().write(to: URL(fileURLWithPath: events))
    return InputMonitor(dryRun: true, environment: ["TYPELESS_TEST_EVENTS": events, "TYPELESS_FAKE_FRONT": app, "TYPELESS_TEST_REQUIRE_PASTE": requirePaste ? "1" : "0", "TYPELESS_TEST_TYPELESS_PID": "42", "TYPELESS_TEST_MANUAL_SETTLE": manualSettle ? "1" : "0"], settlementNow: now)
}
func arm(_ m: InputMonitor) {
    guard case .success(let f) = m.beginAttempt() else { fatalError("focus") }
    m.armAttempt(focus: f, authorize: { true }); m.settleAttempt()
}
func valid(_ m: InputMonitor) -> Bool { if case .success = m.validateAttempt() { return true }; return false }
func delivered(_ m: InputMonitor) -> Bool {
    var value: Bool?
    m.deliver { value = $0 }
    while value == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    return value!
}
// Focus changes are departures even within the same process. Each dedicated
// rule runs independently so TDD reports both settled and buffer failures.
let selectedRule = CommandLine.arguments.dropFirst(2).first
if selectedRule == "settlement-cache" {
    for initial in ["", "> "] {
        for leave in [false, true] {
            let clock = LogicalClock()
            let m = make(requirePaste: true, manualSettle: true, now: { clock.now })
            event(m, "state", ["text": initial])
            event(m, "typeless_paste")
            guard case .success(let f) = m.beginAttempt() else { fatalError("cached paste capture") }
            m.armAttempt(focus: f, pastedText: "hello", authorize: { true })
            clock.now = 0.15
            m.settleAttempt(testEvent: true)
            expect(valid(m), "150ms cached snapshot stays pending instead of cancelling")
            let epoch = m.currentObservationToken!.epoch
            var timerResult: Bool?
            var completions = 0
            m.performDelivery(epoch: epoch) { timerResult = $0; completions += 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.015))
            expect(timerResult == nil && !m.sentAwaitingReport, "zero-delay timer waits for real paste observation")
            if leave { event(m, "deactivate") }
            clock.now = 0.45
            m.settleAttempt(testEvent: true)
            expect(valid(m) && !m.sentAwaitingReport, "still-cached snapshot and departure remain pending")
            clock.now = 0.55
            event(m, "state", ["text": initial + "hello"])
            m.settleAttempt(testEvent: true)
            let deadline = Date().addingTimeInterval(2)
            while timerResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            expect(m.sentAwaitingReport && completions == 1, "fresh 500ms snapshot permits exactly one delivery")
            expect(!delivered(m), "settlement completion and pending departure never duplicate delivery")
        }
    }
    print("monitor checks=\(checks)"); exit(0)
}
if selectedRule == "settlement-delivery" {
    let clock = LogicalClock()
    let m = make(manualSettle: true, now: { clock.now })
    guard case .success(let f) = m.beginAttempt() else { fatalError("pending delivery target") }
    m.armAttempt(focus: f, authorize: { true })
    var result: Bool?
    m.performDelivery(epoch: m.currentObservationToken!.epoch) { result = $0 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    expect(result == nil && valid(m), "timer cannot fail an unsettled attempt")
    m.settleAttempt(testEvent: true)
    let deadline = Date().addingTimeInterval(2)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    expect(result == true, "waiting timer sends after settlement completes")
    print("monitor checks=\(checks)"); exit(0)
}
if selectedRule == "settlement-expiry" {
    for initial in ["", "> "] {
        let clock = LogicalClock()
        let m = make(requirePaste: true, manualSettle: true, now: { clock.now })
        event(m, "state", ["text": initial])
        event(m, "typeless_paste")
        guard case .success(let f) = m.beginAttempt() else { fatalError("unobserved paste target") }
        var cancellations = 0
        var reason = ""
        m.onKeyboard = { reason = $0; cancellations += 1 }
        m.armAttempt(focus: f, pastedText: "hello", authorize: { true })
        clock.now = 0.15; m.settleAttempt(testEvent: true)
        expect(valid(m) && cancellations == 0, "unobserved paste is not cancelled at first sample")
        if initial.isEmpty {
            var timeoutResult: Bool?
            m.performDelivery(epoch: m.currentObservationToken!.epoch) { timeoutResult = $0 }
            clock.now = 1.01
            let deadline = Date().addingTimeInterval(2)
            while timeoutResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            expect(timeoutResult == false, "waiting timer enforces the finite settlement deadline without reading text")
        } else {
            clock.now = 1.01; m.settleAttempt(testEvent: true)
        }
        expect(!valid(m) && !delivered(m) && cancellations == 1, "unobserved paste expires once within its finite budget")
        expect(reason.contains("no pasted text observed"), "expiry retains the no-paste safety reason")
        event(m, "state", ["text": initial + "hello"])
        m.settleAttempt(testEvent: true)
        expect(!delivered(m) && cancellations == 1, "late AX update never revives an expired paste")
    }
    print("monitor checks=\(checks)"); exit(0)
}
if selectedRule == "settlement-autoretry" {
    let clock = LogicalClock()
    let m = make(requirePaste: true, now: { clock.now })
    event(m, "state", ["text": "> "])
    event(m, "typeless_paste")
    guard case .success(let f) = m.beginAttempt() else { fatalError("automatic AX retry target") }
    var sends = 0
    m.onSent = { _ in sends += 1 }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true })
    clock.now = 0.15; m.settleAttempt()
    expect(valid(m), "automatic retry retains a cached first sample")
    event(m, "deactivate")
    var result: Bool?
    m.performDelivery(epoch: m.currentObservationToken!.epoch) { result = $0 }
    clock.now = 0.55
    event(m, "state", ["text": "> hello"])
    let deadline = Date().addingTimeInterval(2)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    expect(result != nil && m.sentAwaitingReport && sends == 1, "scheduled retry observes fresh B and completes pending departure without manual settlement")
    expect(!delivered(m), "automatic settlement and timer do not duplicate a departure")
    print("monitor checks=\(checks)"); exit(0)
}
if selectedRule == "settlement-epoch" {
    let clock = LogicalClock()
    let m = make(requirePaste: true, now: { clock.now })
    event(m, "state", ["text": "old "])
    event(m, "typeless_paste")
    guard case .success(let old) = m.beginAttempt() else { fatalError("old cached capture") }
    m.armAttempt(focus: old, pastedText: "hello", authorize: { true })
    m.settleAttempt()
    expect(valid(m), "old pending settlement schedules a retry")
    var oldDelivery: Bool?
    m.performDelivery(epoch: m.currentObservationToken!.epoch) { oldDelivery = $0 }
    _ = m.endAttempt()
    event(m, "state", ["text": "next ", "caret": 5])
    event(m, "typeless_paste")
    event(m, "state", ["text": "next world", "caret": 10])
    guard case .success(let new) = m.beginAttempt() else { fatalError("new capture after pending settlement") }
    m.armAttempt(focus: new, pastedText: "world", authorize: { true }); m.settleAttempt()
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    expect(oldDelivery == false && valid(m) && !m.sentAwaitingReport, "old settlement and delivery retries cannot affect a new epoch")
    expect(delivered(m), "new settled epoch remains deliverable")
    print("monitor checks=\(checks)"); exit(0)
}
if selectedRule == "settlement-edited" {
    let clock = LogicalClock()
    let m = make(requirePaste: true, manualSettle: true, now: { clock.now })
    event(m, "state", ["text": "draft ", "caret": 6])
    event(m, "typeless_paste")
    guard case .success(let f) = m.beginAttempt() else { fatalError("cached edit target") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true })
    clock.now = 0.15; m.settleAttempt(testEvent: true)
    expect(valid(m), "cached edit target waits for a fresh snapshot")
    clock.now = 0.55
    event(m, "state", ["text": "draft hello!", "caret": 12])
    m.settleAttempt(testEvent: true)
    expect(!valid(m) && !delivered(m), "fresh snapshot still detects edits while AX value was cached")
    print("monitor checks=\(checks)"); exit(0)
}
if ["window-after-settle", "window-during-buffer", "window-before-observation"].contains(selectedRule ?? "") {
    let m = make(requirePaste: true)
    event(m, "state", ["pid": 4242, "text": "draft ", "caret": 6])
    event(m, "typeless_paste")
    event(m, "state", ["text": "draft hello", "caret": 11])
    if selectedRule == "window-before-observation" {
        event(m, "unnotified_state", ["pid": 4242, "window": "window-2", "input": "input-2", "text": "unrelated destination", "caret": 3])
    }
    guard case .success(let original) = m.beginAttempt() else { fatalError("window departure original target") }
    expect(original.processID == 4242, "paste capture retains a nonzero original PID")
    var sends = 0
    m.onSent = { _ in sends += 1 }
    m.armAttempt(focus: original, pastedText: "hello", authorize: { true })
    if selectedRule == "window-after-settle" { m.settleAttempt() }
    if selectedRule != "window-before-observation" {
        event(m, "focus", ["pid": 4242, "window": "window-2", "input": "input-2", "text": "unrelated destination", "caret": 3])
    }
    if selectedRule != "window-after-settle" {
        expect(!m.sentAwaitingReport, "buffer window departure waits for settlement")
        m.settleAttempt()
    }
    // Return posted to the PID would reach the new window's focused input.
    expect(!m.sentAwaitingReport && sends == 0, "same-PID window departure never posts Return to the new window")
    expect(m.preparedReturnTargetPIDs == [4242, 4242], "prepared Return down/up events retain the captured original PID")
    guard case .success(let changed) = m.currentFocus() else { fatalError("changed window identity") }
    expect(changed.processID == original.processID, "window switch stays within original PID")
    event(m, "focus_notification", ["window": "window-3", "input": "input-3"])
    m.settleAttempt()
    expect(!delivered(m) && sends == 0, "later focus and timer cannot send after a same-application departure")
    print("monitor checks=\(checks)")
    exit(0)
}
// Native registration strategy tolerates unsupported value/selection events;
// apps that only expose a value are covered by the polling backup.
do {
    var attempted: [String] = []
    InputMonitor.registerContentNotifications { notification in
        attempted.append(notification)
        return .notificationUnsupported
    }
    expect(attempted.contains(kAXValueChangedNotification), "value notifications are attempted")
    expect(attempted.contains(kAXSelectedTextChangedNotification), "unsupported selection registration is nonfatal")
}
// Key identity and modifier changes do not prove content or caret editing.
do {
    let m = make(); arm(m)
    for key in ["letter", "fn", "tab", "command-tab", "shift", "left-arrow"] {
        event(m, "keyboard", ["origin": "physical", "key": key])
        expect(valid(m), "key alone preserves attempt: \(key)")
    }
    expect(delivered(m), "unchanged input sends at deadline")
    expect(!delivered(m), "delivery consumes attempt only once")
}
// Exercise the exact native handler while another thread holds stateLock
// inside a paste-source lookup. A key must return promptly without poisoning
// the active countdown; later observed content editing must still cancel.
for (code, type, flags) in [(CGKeyCode(0), CGEventType.keyDown, CGEventFlags()),
                            (CGKeyCode(56), .flagsChanged, .maskShift),
                            (CGKeyCode(63), .flagsChanged, .maskSecondaryFn),
                            (CGKeyCode(9), .keyDown, .maskCommand)] {
    let m = make(); arm(m)
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = {
        locked.signal()
        release.wait()
        return "blocked-record"
    }
    DispatchQueue.global().async {
        event(m, "typeless_paste")
        finished.signal()
    }
    expect(locked.wait(timeout: .now() + 2) == .success, "worker holds monitor state lock")
    let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    key.flags = flags
    key.setIntegerValueField(.eventSourceUnixProcessID, value: -1)
    m.handleEvent(type, key)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "key callback never waits for monitor state lock")
    expect(valid(m), "key contention preserves unchanged active attempt")
    event(m, "state", ["text": "confirmed edit"])
    expect(!valid(m), "observed editing still cancels after key contention")
}
// The shared native AX handler must defer a content notification when an
// unrelated AX/database operation holds stateLock. The notification itself is
// never proof of a protected-region edit.
for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
    let m = make(); arm(m)
    let token = m.currentObservationToken!
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "notification-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "AX notification worker holds state lock")
    m.handleAXNotification(notification, token: token)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "AX callback returns without blocking input thread")
    expect(delivered(m), "contended redundant content notification still permits send")
}
// Workspace deactivation uses the same delayed-departure guarantee when a
// database/AX operation holds stateLock. Its timer must not overtake it either.
do {
    let m = make(); arm(m)
    let epoch = m.currentObservationToken!.epoch
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    var sends = 0
    m.onSent = { _ in sends += 1 }
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "deactivation-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "deactivation worker holds state lock")
    m.applicationDeactivated(pid: 0)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "deactivation callback returns without blocking")
    expect(valid(m), "contended deactivation does not poison active countdown")
    var timerResult: Bool?
    m.performDelivery(epoch: epoch) { timerResult = $0 }
    let deadline = Date().addingTimeInterval(2)
    while timerResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    expect(timerResult != nil && m.sentAwaitingReport && sends == 1, "queued deactivation sends once before timer")
    expect(!delivered(m) && sends == 1, "deactivation and timer cannot resend")
}
// Deactivation that arrived during capture is not lost merely because arm
// published a new attempt epoch before the deferred event got the state lock.
do {
    let m = make(requirePaste: true)
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "prearm-deactivation-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "pre-arm deactivation worker holds lock")
    m.applicationDeactivated(pid: 0)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "pre-arm deactivation returns promptly")
    guard case .success(let f) = m.beginAttempt(recordID: "prearm-deactivation-record") else { fatalError("pre-arm deactivation capture") }
    m.armAttempt(focus: f, authorize: { true }); m.settleAttempt()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(m.sentAwaitingReport, "deferred deactivation follows the same capture across arm epoch")
    expect(!delivered(m), "pre-arm deactivation sends once")
}
// The same older event must not mark an unrelated newer paste capture as left.
do {
    let m = make(requirePaste: true)
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "old-deactivation-capture" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "old capture deactivation worker holds lock")
    m.applicationDeactivated(pid: 0)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "old capture deactivation returns promptly")
    m.pasteRecordIDProvider = { "new-deactivation-capture" }
    event(m, "typeless_paste")
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    guard case .success(let f) = m.beginAttempt(recordID: "new-deactivation-capture") else { fatalError("fresh capture after old deactivation") }
    m.armAttempt(focus: f, authorize: { true }); m.settleAttempt()
    expect(valid(m) && !m.sentAwaitingReport, "old deactivation cannot mark a newer capture as departed")
}
do {
    let m = make(); arm(m)
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "ended-deactivation-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "ended deactivation worker holds lock")
    m.applicationDeactivated(pid: 0)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "ended deactivation returns promptly")
    _ = m.endAttempt()
    guard case .success(let f) = m.currentFocus() else { fatalError("new attempt after old deactivation") }
    m.armAttempt(focus: f, authorize: { true }); m.settleAttempt()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(valid(m) && !m.sentAwaitingReport, "old epoch deactivation cannot send or cancel a new attempt")
}
// A focus notification arriving during an AX read is a departure to process,
// not a monitoring gap. A simultaneous timer must wait for that queued event.
for notification in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
    let m = make(); arm(m)
    let token = m.currentObservationToken!
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    var sends = 0
    m.onSent = { _ in sends += 1 }
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "focus-notification-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "focus-notification worker holds state lock")
    let fakeTarget = AXUIElementCreateApplication(0)
    m.handleAXNotification(notification, token: token, element: fakeTarget)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "contended focus callback returns immediately")
    expect(valid(m), "contended focus notification does not poison the active attempt")
    var timerResult: Bool?
    m.performDelivery(epoch: token.epoch) { timerResult = $0 }
    let deadline = Date().addingTimeInterval(2)
    while timerResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    expect(timerResult == false, "timer finishes after the queued focus notification without sending")
    expect(!m.sentAwaitingReport && sends == 0, "queued same-application focus departure cancels before a competing timer")
    m.handleAXNotification(notification, token: token, element: fakeTarget)
    expect(!delivered(m) && sends == 0, "duplicate focus notification and timer cannot send")
}
// A deferred value notification must compare the latest protected region
// before a timer can send; reverting afterwards never resurrects the attempt.
do {
    let m = make(); arm(m)
    let token = m.currentObservationToken!
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "edited-notification-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "deferred edit worker holds lock")
    m.handleAXNotification(kAXValueChangedNotification, token: token)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "deferred edit callback never blocks")
    event(m, "unnotified_state", ["text": "real protected edit"])
    expect(!delivered(m), "deferred content comparison cancels real edit before timer sends")
    event(m, "state", ["text": ""])
    expect(!delivered(m), "deferred edit cancellation is permanent")
}
// Queued callbacks from the old observer/epoch cannot cancel a freshly armed
// attempt. A stale focus payload would be dangerous if its token were ignored.
do {
    let m = make(); arm(m)
    let oldToken = m.currentObservationToken!
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "old-observer-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "stale observer worker holds lock")
    m.handleAXNotification(kAXSelectedTextChangedNotification, token: oldToken)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "stale observer callback returns promptly")
    _ = m.endAttempt()
    event(m, "state", ["text": "new baseline"])
    guard case .success(let f) = m.currentFocus() else { fatalError("new observer focus") }
    m.armAttempt(focus: f, authorize: { true }); m.settleAttempt()
    let newToken = m.currentObservationToken!
    let staleObserver = InputObservationToken(observerID: oldToken.observerID + 1, epoch: newToken.epoch)
    let staleElement = AXUIElementCreateApplication(0)
    m.handleAXNotification(kAXFocusedUIElementChangedNotification, token: oldToken, element: staleElement)
    m.handleAXNotification(kAXFocusedUIElementChangedNotification, token: staleObserver, element: staleElement)
    expect(delivered(m), "old observer and old epoch cannot cancel a new attempt")
}
// A nonempty but unchanged input is also a failed paste unless a trusted
// selection proves that the transcription replaced exactly the same text.
for selectionAvailable in [true, false] {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "> ", "caret": 0, "selectionAvailable": selectionAvailable])
    event(m, "typeless_paste")
    guard case .success(let f) = m.beginAttempt() else { fatalError("unchanged nonempty paste target") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(!delivered(m), "unchanged nonempty snapshot B without a trusted replacement cannot send")
}
// The actual event-thread timer branch must retry state-lock contention,
// rather than interpreting an unrelated AX read as a cancelled countdown.
do {
    let m = make(); arm(m)
    let epoch = m.currentObservationToken!.epoch
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "delivery-lock-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "delivery worker holds state lock")
    var result: Bool?
    var completions = 0
    m.performDelivery(epoch: epoch) { result = $0; completions += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    let completedWhileLocked = result != nil
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "delivery worker releases state lock")
    expect(!completedWhileLocked, "contended delivery never completes early as a failure")
    let deadline = Date().addingTimeInterval(2)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    expect(result == true && completions == 1, "released unchanged delivery succeeds exactly once")
}
for rearm in [false, true] {
    let m = make(); arm(m)
    let oldEpoch = m.currentObservationToken!.epoch
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "cancelled-delivery-lock-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "old delivery worker holds state lock")
    var oldResult: Bool?
    var oldCompletions = 0
    m.performDelivery(epoch: oldEpoch) { oldResult = $0; oldCompletions += 1 }
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "old delivery worker releases state lock")
    _ = m.endAttempt()
    if rearm {
        guard case .success(let f) = m.currentFocus() else { fatalError("rearmed retry target") }
        m.armAttempt(focus: f, authorize: { true }); m.settleAttempt()
    }
    let deadline = Date().addingTimeInterval(2)
    while oldResult == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    expect(oldResult == false && oldCompletions == 1, "cancelled old delivery retry completes once without sending")
    expect(!m.sentAwaitingReport, "old delivery retry never sends after cancellation or into new attempt")
    if rearm { expect(delivered(m), "old epoch retry cannot cancel a newly armed attempt") }
}
// A missed verified paste invalidates its cached target without poisoning
// the current countdown. A later record cannot consume an older capture.
do {
    let m = make(requirePaste: true)
    m.armAttempt(focus: FocusSnapshot(bundleID: app), authorize: { true }); m.settleAttempt()
    let locked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    m.pasteRecordIDProvider = { locked.signal(); release.wait(); return "blocked-record" }
    DispatchQueue.global().async { event(m, "typeless_paste"); finished.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "paste worker holds monitor lock")
    let paste = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
    paste.flags = .maskCommand
    paste.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
    m.handleEvent(.keyDown, paste)
    release.signal()
    expect(finished.wait(timeout: .now() + 2) == .success, "missed paste never blocks event callback")
    expect(valid(m), "missed paste capture does not cancel unchanged current attempt")
    _ = m.endAttempt()
    if case .success = m.beginAttempt(recordID: "blocked-record") { expect(false, "missed paste cannot reuse cached target") }
    else { expect(true, "missed paste cannot reuse cached target") }
}
// The same ancestry classifier drives native mouse hit testing. Unknown AX
// parents, deadline failures, depth limits and cycles never prove an outside hit.
let fakeParents = [1: 2, 2: 10, 3: 10, 4: 1]
func fakeStep(_ node: Int) -> InputParentStep<Int> {
    if node == 10 || node == 11 { return .boundary }
    if let parent = fakeParents[node] { return .parent(parent) }
    return .unavailable
}
func relation(_ hit: Int, depth: Int = 24) -> InputTargetRelation {
    InputMonitor.classifyInputTarget(hit: hit, original: 1, equal: ==, parentStep: fakeStep, maximumDepth: depth)
}
expect(relation(1) == .inside, "direct input hit is inside")
expect(relation(4) == .inside, "input child hit is inside")
expect(relation(2) == .inside, "editor ancestor hit is inside")
expect(relation(3) == .outside, "separate window branch is outside")
expect(relation(10) == .inside, "same-window hit may contain the input and never proves an outside click")
expect(relation(11) == .outside, "different complete window branches prove an outside click")
expect(relation(99) == .unknown, "missing AX parent or timeout remains unknown")
expect(relation(4, depth: 1) == .unknown, "incomplete depth-limited ancestry remains unknown")
let cycle = InputMonitor.classifyInputTarget(hit: 20, original: 1, equal: ==, parentStep: { node -> InputParentStep<Int> in
    if node == 20 { return .parent(21) }
    if node == 21 { return .parent(20) }
    return fakeStep(node)
})
expect(cycle == .unknown, "cyclic ancestry remains unknown")
// Diagnostics name where each side of an inconclusive walk stopped and why.
func trace(_ hit: Int, depth: Int = InputMonitor.ancestryDepthLimit, step: (Int) -> InputParentStep<Int> = fakeStep) -> InputAncestryTrace {
    var trace = InputAncestryTrace()
    _ = InputMonitor.classifyInputTarget(hit: hit, original: 1, equal: ==, parentStep: step, maximumDepth: depth, trace: &trace)
    return trace
}
expect(trace(3) == InputAncestryTrace(hitSteps: 2, originalSteps: 3, hitEnd: .boundary, originalEnd: .open),
       "outside trace records both climbs")
let unreadable = trace(99)
expect(unreadable.summary == "hit=1/unavailable original=3/boundary", "unreadable hit side is reported")
expect(InputMonitor.ancestryCause(unreadable, failure: .deadline) == "deadline", "expired budget is named")
expect(InputMonitor.ancestryCause(unreadable, failure: .error(.cannotComplete)) == "ax_timeout", "unanswered read is named")
expect(InputMonitor.ancestryCause(unreadable, failure: .error(.invalidUIElement)) == "element_invalid", "destroyed element is named")
expect(InputMonitor.ancestryCause(unreadable, failure: .unexpectedType) == "unreadable", "other read failures are grouped")
expect(InputMonitor.ancestryCause(trace(4, depth: 1), failure: nil) == "depth", "depth limit is named")
let cyclic = trace(20, step: { node in node == 20 ? .parent(21) : node == 21 ? .parent(20) : fakeStep(node) })
expect(cyclic.hitEnd == .cycle && InputMonitor.ancestryCause(cyclic, failure: nil) == "cycle", "cycle is named")
// A composer nested 33 levels below its window, clicked from a 12-level branch:
// the walks only meet at the window, which the old 24-level limit never reached.
func chainStep(_ node: Int) -> InputParentStep<Int> {
    if node == 0 { return .boundary }
    if node == 1033 || node == 2012 || node == 3150 { return .parent(0) }
    return .parent(node + 1)
}
expect(InputMonitor.classifyInputTarget(hit: 2000, original: 1000, equal: ==, parentStep: chainStep) == .outside,
       "deep composer reaches the shared window within the default limit")
expect(InputMonitor.classifyInputTarget(hit: 2000, original: 1000, equal: ==, parentStep: chainStep, maximumDepth: 24) == .unknown,
       "the former 24-level limit leaves the same click inconclusive")
expect(InputMonitor.classifyInputTarget(hit: 2005, original: 2000, equal: ==, parentStep: chainStep) == .inside,
       "an ancestor of a deep original is inside")
let tooDeep = trace(2000, step: { node in node == 1 ? .parent(3000) : chainStep(node) })
expect(InputMonitor.ancestryCause(tooDeep, failure: nil) == "depth" && tooDeep.originalSteps == InputMonitor.ancestryDepthLimit,
       "a chain beyond the limit stays inconclusive")
do {
    let probe = AXReadProbe()
    probe.read(); probe.fail(.error(.cannotComplete), "AXRole")
    probe.read(); probe.fail(.deadline, "AXParent")
    expect(probe.reads == 2 && probe.failureSummary == "ax-25204@AXRole", "probe keeps the first failed read")
}
do {
    let m = make(); arm(m)
    m.handleMouseTarget(relation(99), hitPID: 0)
    expect(valid(m) && !m.sentAwaitingReport, "unknown mouse relation preserves active attempt")
}
for hit in [3, 99] {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "draft ", "caret": 6])
    event(m, "typeless_paste")
    event(m, "state", ["text": "draft hello", "caret": 11])
    m.handleMouseTarget(relation(hit), hitPID: 0)
    guard case .success(let f) = m.beginAttempt() else { fatalError("pre-arm click capture") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(m.sentAwaitingReport == (hit == 3), "pre-arm outside click records departure; unknown does not")
}
// An AX value notification is a prompt to compare content, not an edit itself.
do {
    let m = make(); arm(m); event(m, "edit_notification")
    expect(valid(m), "redundant value notification preserves attempt")
    event(m, "state", ["text": "edited"])
    event(m, "edit_notification")
    expect(!valid(m), "changed protected content cancels permanently")
    event(m, "state", ["text": ""])
    expect(!delivered(m), "reverting content does not resurrect cancelled attempt")
}
// Any outside same-app control sends before click, regardless of role/modifiers.
do {
    let m = make(); arm(m)
    event(m, "transition", ["verified": true, "targetRole": "AXButton", "left": false, "modifiers": ["shift"]])
    expect(m.sentAwaitingReport, "outside click sends immediately")
    expect(m.sentReason == "before-focus-change", "outside click records pre-click delivery")
}
do {
    let m = make(); arm(m)
    event(m, "transition", ["sameInput": true])
    expect(valid(m), "original input and descendants preserve attempt")
    event(m, "focus_notification", ["window": "another-window"])
    expect(!m.sentAwaitingReport && !delivered(m), "same-app window departure cancels instead of posting Return to the new window")
}
// Expiry confirms the frontmost application still focuses the original input,
// covering a focus move whose notification has not been handled yet.
for field in ["input", "window"] {
    let m = make(); arm(m)
    var reason = ""
    m.onKeyboard = { reason = $0 }
    event(m, "unnotified_state", [field: "\(field)-2"])
    expect(!delivered(m), "expiry after an unobserved \(field) move does not send")
    expect(reason.contains(InputMonitor.sameApplicationDepartureReason), "expiry names the \(field) departure")
}
do {
    let m = make(); arm(m)
    expect(delivered(m), "expiry with focus still on the original input sends")
}
do {
    let m = make(); arm(m)
    event(m, "deactivate")
    expect(m.sentAwaitingReport, "deactivation sends immediately to original PID")
}
do {
    let m = make(); guard case .success(let f) = m.beginAttempt() else { fatalError() }
    m.armAttempt(focus: f, authorize: { true })
    event(m, "deactivate")
    expect(!m.sentAwaitingReport, "buffer departure waits for settle")
    m.settleAttempt()
    expect(m.sentAwaitingReport, "buffer departure sends once settled")
}
do {
    let m = make(); arm(m)
    event(m, "capability", ["focusReadable": false])
    expect(delivered(m), "deadline never re-reads AX content or selection")
}
do {
    let m = make(); arm(m)
    event(m, "capability", ["processAlive": false])
    expect(!delivered(m), "process exit cancels")
}
do {
    let m = make(); event(m, "state", ["selectionAvailable": false]); arm(m)
    expect(valid(m), "missing selection does not block usable input")
    expect(delivered(m), "missing selection still sends")
}
// Paste capture happens before an attempt, and is bound to one database row.
do {
    let m = make(requirePaste: true)
    m.pasteRecordIDProvider = { "record-a" }
    event(m, "typeless_paste")
    if case .success = m.beginAttempt(recordID: "record-b") { expect(false, "wrong record cannot consume paste") }
    else { expect(true, "wrong record preserves captured paste") }
    guard case .success(let f) = m.beginAttempt(recordID: "record-a") else { fatalError("matching capture") }
    m.armAttempt(focus: f, authorize: { true }); m.settleAttempt(); _ = m.endAttempt()
    if case .success = m.beginAttempt(recordID: "record-a") { expect(false, "paste is single-use") }
    else { expect(true, "paste is single-use") }
}
// The original input is frozen by the pre-paste event even when foreground
// changed before the completed database row was polled.
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "draft ", "caret": 6])
    event(m, "typeless_paste")
    event(m, "state", ["text": "draft hello", "caret": 11])
    event(m, "focus", ["app": "com.example.other", "input": "other-input"])
    guard case .success(let f) = m.beginAttempt() else { fatalError("captured target") }
    expect(f.bundleID == app && f.text == "draft ", "snapshot A belongs to original input")
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(m.sentAwaitingReport, "pre-arm departure settles captured original input before send")
}
// Content outside the pasted line can refresh, including editors that expose
// no caret or a constant 0,0 range. Editing the pasted line still cancels.
for selectionAvailable in [false, true] {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "old history\n> ", "selectionAvailable": selectionAvailable])
    event(m, "typeless_paste")
    event(m, "state", ["text": "old history\n> hello"])
    guard case .success(let f) = m.beginAttempt() else { fatalError("terminal capture") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    event(m, "state", ["text": "new history\n> hello"])
    event(m, "edit_notification")
    expect(valid(m), "unrelated content refresh preserves protected pasted line")
    event(m, "state", ["text": "new history\n> edited"])
    expect(!valid(m), "protected pasted line editing cancels")
}
do {
    let m = make(); arm(m)
    event(m, "state", ["caret": 3])
    expect(!valid(m), "caret change cancels even without keyboard activity")
}
do {
    let m = make()
    guard case .success(let f) = m.beginAttempt() else { fatalError() }
    m.armAttempt(focus: f, authorize: { true })
    event(m, "focus", ["window": "other-window", "input": "other-input", "text": "other content"])
    expect(!m.sentAwaitingReport, "buffer focus departure waits")
    m.settleAttempt()
    expect(!m.sentAwaitingReport && !delivered(m), "buffer focus departure cancels once settled")
}
do {
    let m = make(); guard case .success(let f) = m.beginAttempt() else { fatalError() }
    m.armAttempt(focus: f, authorize: { false }); m.settleAttempt()
    event(m, "deactivate")
    expect(!m.sentAwaitingReport, "leave-to-send requires authorization")
    expect(!delivered(m), "denied authorization permanently consumes attempt")
}
// The user can edit and leave before the next value notification or 100 ms
// foreground poll. Departure checks the cached original input one final time.
for departure in ["deactivate", "focus_notification"] {
    let m = make(); arm(m)
    event(m, "unnotified_state", ["text": "edit before observer callback"])
    event(m, departure, ["window": "another-window"])
    expect(!m.sentAwaitingReport, "departure cannot send an unobserved content edit")
    expect(!delivered(m), "departure edit cancels permanently")
}
do {
    let m = make(); arm(m)
    event(m, "unnotified_state", ["caret": 4])
    expect(!valid(m), "caret movement observed while original remains focused cancels")
    event(m, "deactivate")
    expect(!m.sentAwaitingReport, "departure cannot revive a confirmed caret edit")
}
do {
    let m = make(); arm(m)
    event(m, "unnotified_state", ["caret": 4])
    event(m, "deactivate")
    expect(m.sentAwaitingReport, "after confirmed blur a changed selection alone is not proof of editing")
}
// Text can be temporarily unreadable while identity is still confirmed. A
// temporarily unreadable focus identity is not itself proof of editing.
do {
    let m = make(); arm(m)
    event(m, "capability", ["focusReadable": false, "identityReadable": true])
    expect(valid(m), "unreadable text does not cancel confirmed original identity")
    expect(delivered(m), "timer never re-reads unreadable content")
}
do {
    let m = make(); arm(m)
    event(m, "capability", ["identityReadable": false])
    event(m, "deactivate")
    expect(m.sentAwaitingReport && m.sentReason == "original-pid", "unreadable current identity does not cancel original-PID departure")
    event(m, "capability", ["identityReadable": true])
    expect(!delivered(m), "completed departure cannot send twice after identity recovers")
}
do {
    let m = make(); arm(m)
    event(m, "capability", ["identityReadable": false])
    expect(valid(m) && !m.sentAwaitingReport, "foreground identity inspection failure preserves countdown")
    event(m, "unnotified_state", ["text": "edited while current identity is unreadable"])
    expect(!valid(m), "captured input edits still cancel when current identity is unreadable")
}
// An input may report caret offsets that omit characters its value contains.
// A clean append still settles and sends; later caret moves still cancel.
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "ab\ncd\n", "caret": 3])
    event(m, "typeless_paste")
    event(m, "state", ["text": "ab\ncd\nhello", "caret": 8])
    guard case .success(let f) = m.beginAttempt() else { fatalError("offset caret capture") }
    var reason = ""
    m.onKeyboard = { reason = $0 }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(valid(m) && reason.isEmpty, "offset caret does not turn a clean append into an edit")
    event(m, "state", ["caret": 5])
    expect(!valid(m), "caret movement after settlement still cancels")
}
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "ab\ncd\n", "caret": 3])
    event(m, "typeless_paste")
    event(m, "state", ["text": "ab\ncd\nhello", "caret": 8])
    guard case .success(let f) = m.beginAttempt() else { fatalError("offset caret send") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(delivered(m), "offset caret clean append is delivered at expiry")
}
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "ab\ncd\n", "caret": 3])
    event(m, "typeless_paste")
    event(m, "state", ["text": "ab\ncd\nhello", "caret": 8])
    guard case .success(let f) = m.beginAttempt() else { fatalError("offset caret edit") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(valid(m), "clean append settles before the edit")
    // The protected region comes from the located paste, not the offset caret.
    event(m, "unnotified_state", ["text": "ab\ncd\nhellX"])
    expect(!valid(m), "editing the pasted line after settlement cancels")
}
// A verified paste event alone is not evidence that any text reached the
// input. A completely empty snapshot B must never cause an empty Return.
do {
    let m = make(requirePaste: true)
    event(m, "typeless_paste")
    guard case .success(let f) = m.beginAttempt() else { fatalError("empty captured paste") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(!delivered(m), "empty snapshot B without observed pasted text cannot send")
}
do {
    let m = make(requirePaste: true)
    event(m, "typeless_paste")
    event(m, "state", ["text": "hello", "caret": 5])
    guard case .success(let f) = m.beginAttempt() else { fatalError("normal captured paste") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(delivered(m), "observed nonempty paste still sends")
}
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "hello", "caret": 0, "selectionLength": 5])
    event(m, "typeless_paste")
    event(m, "state", ["text": "hello", "caret": 5, "selectionLength": 0])
    guard case .success(let f) = m.beginAttempt() else { fatalError("identical selected-text replacement") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(delivered(m), "same nonempty text replacing a selection is a valid paste")
}
// Historical matching text is not evidence that a different selection was replaced.
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "hello world", "caret": 6, "selectionLength": 5])
    event(m, "typeless_paste")
    event(m, "state", ["text": "hello world", "caret": 11, "selectionLength": 0])
    guard case .success(let f) = m.beginAttempt() else { fatalError("failed selected paste") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(!delivered(m), "failed paste must not submit historical matching text")
}
// Identical replacements must protect the selected occurrence, not the last match.
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "hello\nhello", "caret": 0, "selectionLength": 5])
    event(m, "typeless_paste")
    event(m, "state", ["text": "hello\nhello", "caret": 5, "selectionLength": 0])
    guard case .success(let f) = m.beginAttempt() else { fatalError("repeated selected paste") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(valid(m), "identical replacement settles")
    event(m, "unnotified_state", ["text": "hellX\nhello"])
    expect(!valid(m), "editing the selected first occurrence cancels")
}
// Focus departure still requires every send authorization and health gate.
for failure in ["authorization", "new-record", "permission", "secure-input", "process-exit"] {
    let m = make()
    guard case .success(let original) = m.beginAttempt() else { fatalError("gated window departure") }
    var authorized = true
    var newerRecord = false
    m.armAttempt(focus: original, authorize: { authorized && !newerRecord }); m.settleAttempt()
    switch failure {
    case "authorization": authorized = false
    case "new-record": newerRecord = true
    case "permission": event(m, "capability", ["inputMonitoring": false])
    case "secure-input": event(m, "capability", ["secureInput": true])
    default: event(m, "capability", ["processAlive": false])
    }
    event(m, "focus", ["window": "window-2", "input": "input-2"])
    expect(!m.sentAwaitingReport && !delivered(m), "window departure respects authorization and health: \(failure)")
}
// Buffering may finish the system paste, but may not absorb an intervening
// user edit into snapshot B. The same protection works without caret metadata.
for selectionAvailable in [true, false] {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "draft ", "caret": selectionAvailable ? 6 : 0,
                        "selectionAvailable": selectionAvailable])
    event(m, "typeless_paste")
    event(m, "state", ["text": "draft hello!", "caret": selectionAvailable ? 12 : 0])
    guard case .success(let f) = m.beginAttempt() else { fatalError("buffer capture") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    expect(!delivered(m), "buffer editing is not accepted as pasted baseline")
}
do {
    let m = make(requirePaste: true)
    event(m, "state", ["text": "draft ", "caret": 6])
    event(m, "typeless_paste")
    event(m, "state", ["text": "draft hello", "caret": 3])
    guard case .success(let f) = m.beginAttempt() else { fatalError("buffer caret capture") }
    m.armAttempt(focus: f, pastedText: "hello", authorize: { true }); m.settleAttempt()
    // Caret offsets are never compared with text lengths, so the settled caret
    // is the baseline; only movement after settlement is an edit signal.
    expect(delivered(m), "the settled caret becomes the baseline for a clean paste")
}
print("monitor checks=\(checks)")
''')
            binary = root / "monitor-unit"
            sources = [ROOT / "InputMonitor.swift", ROOT / "Settings.swift"]
            if (ROOT / "PasteBaseline.swift").exists():
                sources.append(ROOT / "PasteBaseline.swift")
            compiled = subprocess.run(["swiftc", "-O", *map(str, sources), str(source), "-o", str(binary)],
                                      capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            (root / "events.jsonl").touch()
            for rule in ("all", "window-after-settle", "window-during-buffer", "window-before-observation",
                         "settlement-cache", "settlement-delivery", "settlement-expiry", "settlement-autoretry", "settlement-epoch", "settlement-edited"):
                with self.subTest(rule=rule):
                    result = subprocess.run([binary, str(root / "events.jsonl"), rule],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("monitor checks=", result.stdout)

if __name__ == "__main__":
    unittest.main()
