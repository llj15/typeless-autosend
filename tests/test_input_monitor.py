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
func make(requirePaste: Bool = false) -> InputMonitor {
    try! Data().write(to: URL(fileURLWithPath: events))
    return InputMonitor(dryRun: true, environment: ["TYPELESS_TEST_EVENTS": events, "TYPELESS_FAKE_FRONT": app, "TYPELESS_TEST_REQUIRE_PASTE": requirePaste ? "1" : "0", "TYPELESS_TEST_TYPELESS_PID": "42"])
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
    expect(!m.sentAwaitingReport && !valid(m), "changed first responder cancels instead of sending to the new input")
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
    expect(!m.sentAwaitingReport && !valid(m), "buffer focus change cancels instead of sending to new responder")
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
    event(m, "deactivate")
    expect(!m.sentAwaitingReport, "departure cannot send an unobserved caret edit")
}
// Text can be temporarily unreadable while identity is still confirmed. A
// routing-identity failure is different: leaving must fail closed permanently.
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
    expect(!m.sentAwaitingReport, "departure never sends when input routing identity is unknown")
    event(m, "capability", ["identityReadable": true])
    expect(!delivered(m), "unknown departure identity cancellation is permanent")
}
do {
    let m = make(); arm(m)
    event(m, "capability", ["identityReadable": false])
    expect(!valid(m), "foreground identity inspection failure cancels")
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
    expect(!delivered(m), "buffer caret movement is not accepted as post-paste caret")
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
            result = subprocess.run([binary, str(root / "events.jsonl")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("monitor checks=", result.stdout)

if __name__ == "__main__":
    unittest.main()
