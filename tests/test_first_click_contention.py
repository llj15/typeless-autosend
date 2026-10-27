"""First mouse-down contention through native handlers, with simulated boundaries."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HARNESS = r'''
import AppKit
import ApplicationServices
import Foundation
let app = "com.example.editor"
let rule = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
final class RecordedPosts {
    private let lock = NSLock()
    private var values: [(String, [CGEvent])] = []
    func append(_ route: InputEventRoute, _ events: [CGEvent]) {
        let name: String
        switch route { case .process: name = "pid"; case .tap: name = "tap"; case .session: name = "session" }
        lock.lock(); values.append((name, events)); lock.unlock()
    }
    var snapshot: [(String, [CGEvent])] { lock.lock(); defer { lock.unlock() }; return values }
}
final class TestClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func expire() { lock.lock(); time = 1.1; lock.unlock() }
}
final class ClickResult {
    private let lock = NSLock()
    private var value: CGEvent?
    func set(_ event: CGEvent?) { lock.lock(); value = event; lock.unlock() }
    var result: CGEvent? { lock.lock(); defer { lock.unlock() }; return value }
}
let posts = RecordedPosts(), clock = TestClock()
let monitor = InputMonitor(dryRun: true,
    environment: ["TYPELESS_FAKE_FRONT": app, "TYPELESS_TEST_MANUAL_SETTLE": "1", "TYPELESS_TEST_EVENTS": path, "TYPELESS_TEST_TYPELESS_PID": "42"],
    settlementNow: { clock.now }, eventPoster: { posts.append($0, $1) })
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL [\(rule)]: \(message)\n", stderr); exit(1) }
}
func pump(_ seconds: TimeInterval = 0.035) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func simulated(_ type: String, _ fields: [String: Any] = [:]) {
    var item = fields; item["type"] = type
    var data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    data.append(try! JSONSerialization.data(withJSONObject: item)); data.append(10)
    try! data.write(to: URL(fileURLWithPath: path)); monitor.poll()
}
func mouse(_ type: CGEventType) -> CGEvent {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left)!
}
func key(_ down: Bool = true) -> CGEvent { CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)! }
func paste() {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
    event.flags = .maskCommand; event.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
    monitor.handleEvent(.keyDown, event)
}
func labels(_ events: [CGEvent]) -> [String] {
    events.map { ($0.type == .keyDown || $0.type == .keyUp) ? "\($0.type.rawValue):\($0.getIntegerValueField(.keyboardEventKeycode))" : "\($0.type.rawValue)" }
}
func returnCount() -> Int {
    let events: [CGEvent] = posts.snapshot.flatMap { $0.1 }
    return events.filter { $0.type == CGEventType.keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 36 }.count
}
func claimCarrier() {
    let carriers = posts.snapshot.flatMap { $0.1 }.filter { $0.type == .null }
    expect(carriers.count == 1, "exactly one carrier was posted after classification")
    let output = monitor.handleTapEvent(.null, carriers[0])
    expect(output?.type == .leftMouseDown, "carrier returns the saved down after Return")
    expect(returnCount() == 1, "one Return reaches the injected poster before down is returned")
    expect(posts.snapshot.contains { $0.0 == "tap" && labels($0.1) == ["10:36", "11:36"] }, "Return uses the current callback proxy")
    pump()
    let batches = posts.snapshot.filter { $0.0 == "session" && $0.1.first?.type != .null }
    expect(batches.count == 1 && labels(batches[0].1) == ["2", "10:0", "11:0"], "up and subsequent key pair follow returned down exactly once")
}
let focus = FocusSnapshot(bundleID: app)
let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
var blockAuthorization = rule == "late-timer"
var authorizationCount = 0
var completedBeforeClaim = false
let prearm = rule == "prearm" || rule == "capture-handoff"
if prearm { paste() }
else if rule != "idle" {
    monitor.armAttempt(focus: focus, authorize: {
        authorizationCount += 1
        if blockAuthorization { blockAuthorization = false; locked.signal(); release.wait() }
        return true
    })
    if rule != "buffer" { monitor.settleAttempt(testEvent: true) }
}
if rule == "late-timer" {
    DispatchQueue.global().async { monitor.deliver { _ in completedBeforeClaim = true }; done.signal() }
} else {
    // This real callback executes under the same state mutex as AX inspection.
    monitor.onMonitoringChange = { _ in locked.signal(); release.wait() }
    DispatchQueue.global().async { monitor.poll(); done.signal() }
}
expect(locked.wait(timeout: .now() + 2) == .success, "fixture owns state lock")
let down = mouse(.leftMouseDown)
let firstResult = ClickResult()
let callbackDone = DispatchSemaphore(value: 0)
let relation: InputTargetRelation = ["inside", "departure-inside"].contains(rule) ? .inside : (["unknown", "departure-unknown"].contains(rule) ? .unknown : .outside)
DispatchQueue.global().async {
    firstResult.set(monitor.handleTapEvent(.leftMouseDown, down, mouseTarget: relation))
    callbackDone.signal()
}
expect(callbackDone.wait(timeout: .now() + .milliseconds(150)) == .success, "first-down callback never waits for the state mutex")
if rule == "idle" {
    expect(firstResult.result === down, "idle monitoring does not hold a user's click")
    release.signal(); expect(done.wait(timeout: .now() + 2) == .success, "idle fixture released")
    pump(); expect(posts.snapshot.isEmpty, "idle click has no synthetic replay or Return")
    print("first click \(rule) passed"); exit(0)
}
expect(firstResult.result == nil, "first mouse-down is held during state inspection")
for event in [mouse(.leftMouseUp), key(), key(false)] {
    expect(monitor.handleTapEvent(event.type, event) == nil, "following input stays behind the held down")
}
expect(posts.snapshot.isEmpty, "no replay or Return can pass the down while state is unresolved")
if rule == "timeout" {
    clock.expire(); monitor.checkHeldInputTimeout(); pump()
    expect(returnCount() == 0, "independent timeout releases without Return while state remains locked")
    expect(posts.snapshot.count == 1 && labels(posts.snapshot[0].1) == ["1", "2", "10:0", "11:0"], "timeout preserves the complete input order")
}
if rule == "limit" {
    for _ in 0..<252 { expect(monitor.handleTapEvent(.keyDown, key()) == nil, "queue remains bounded and holds input through limit") }
    pump()
    expect(posts.snapshot.count == 1 && posts.snapshot[0].1.count == 256, "queue limit drains the original stream once")
    expect(returnCount() == 0, "queue limit cannot submit")
}
release.signal()
expect(done.wait(timeout: .now() + 2) == .success, "fixture releases state mutex")
monitor.onMonitoringChange = nil
// In dry-run, resolver continuations are queued exclusively on the main queue.
// This top-level main thread does not pump until after these synchronous owner
// changes, so stale-resolver cases have an explicit ordering, not a 5 ms race.
if rule == "end" || rule == "new-attempt" { _ = monitor.endAttempt() }
if rule == "new-attempt" { monitor.armAttempt(focus: focus, authorize: { true }); monitor.settleAttempt(testEvent: true) }
if rule == "new-paste" { paste() }
if rule == "permission" { simulated("capability", ["inputMonitoring": false]) }
if rule == "departure-inside" || rule == "departure-unknown" { monitor.applicationDeactivated(pid: focus.processID) }
if rule == "other-app" { simulated("focus", ["app": "com.example.other"]) }
if rule == "timer" {
    monitor.deliver { _ in completedBeforeClaim = true }
    expect(authorizationCount == 0, "unresolved timer does not read authorization before classification")
}
if rule == "capture-handoff" {
    guard case .success = monitor.beginAttempt() else { fatalError("consume original capture") }
}
pump()
if ["timeout", "limit", "end", "new-attempt", "new-paste", "permission"].contains(rule) {
    expect(returnCount() == 0, "ended, superseded or failed unresolved click never posts Return")
    expect(posts.snapshot.count == 1, "old resolver cannot replay an input batch twice")
    if rule == "new-attempt" {
        monitor.deliver { _ in }; pump()
        expect(returnCount() == 1, "old failure and resolver cannot poison a newly armed epoch")
    } else if ["timeout", "limit", "new-paste"].contains(rule) {
        if case .success = monitor.validateAttempt() { expect(false, "failed old owner cannot send later") }
    }
} else if rule == "inside" || rule == "unknown" {
    expect(returnCount() == 0, "inside or unknown clicks do not prove departure")
    expect(posts.snapshot.count == 1 && labels(posts.snapshot[0].1) == ["1", "2", "10:0", "11:0"], "pass-through preserves original input order")
    if case .failure(let error) = monitor.validateAttempt() { expect(false, "ordinary pass-through must not cancel: \(error.reason)") }
} else if ["departure-inside", "departure-unknown", "other-app"].contains(rule) {
    expect(returnCount() == 1 && monitor.sentAwaitingReport, "independent confirmed departure survives non-outside click classification")
    expect(posts.snapshot.contains { $0.0 == "pid" }, "independent departure retains original-process delivery")
    expect(!posts.snapshot.contains { $0.1.first?.type == .null }, "non-outside clicks never request outside-click carrier")
} else {
    expect(!completedBeforeClaim, "a timer cannot report failure while its first click awaits classification")
    if rule == "buffer" {
        expect(posts.snapshot.isEmpty, "buffered outside click waits for settled paste")
        monitor.settleAttempt(testEvent: true)
    }
    if prearm {
        expect(posts.snapshot.isEmpty, "pre-arm outside click waits for a bound attempt")
        let original: FocusSnapshot
        if rule == "capture-handoff" { original = focus }
        else { guard case .success(let captured) = monitor.beginAttempt() else { fatalError("capture") }; original = captured }
        monitor.armAttempt(focus: original, authorize: { true }); monitor.settleAttempt(testEvent: true)
    }
    claimCarrier()
    expect(monitor.sentAwaitingReport, "lock contention sends unchanged input instead of cancelling")
}
print("first click \(rule) passed")
'''

class FirstClickContentionTests(unittest.TestCase):
    def test_first_mouse_down_is_not_lost_during_state_inspection(self):
        with tempfile.TemporaryDirectory(prefix="autosend-first-click-") as directory:
            work = Path(directory)
            source = work / "main.swift"
            source.write_text(HARNESS)
            binary = work / "first-click"
            compiled = subprocess.run(["swiftc", "-O", str(ROOT / "InputMonitor.swift"), str(ROOT / "PasteBaseline.swift"), str(ROOT / "Settings.swift"), str(source), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            events = work / "events.jsonl"
            for rule in ["outside", "inside", "unknown", "idle", "buffer", "prearm", "capture-handoff", "timer", "late-timer", "departure-inside", "departure-unknown", "other-app", "timeout", "limit", "end", "new-attempt", "new-paste", "permission"]:
                with self.subTest(rule=rule):
                    events.write_text("")
                    result = subprocess.run([str(binary), rule, str(events)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
