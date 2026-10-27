"""Pure CGEvent construction and an injected poster; no native input is posted."""
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
let path = CommandLine.arguments[1]
var posts: [(String, [CGEvent])] = []
var clock: TimeInterval = 0
let rule = CommandLine.arguments[2]
func label(_ event: CGEvent) -> String {
    if event.type == .keyDown || event.type == .keyUp { return "\(event.type.rawValue):\(event.getIntegerValueField(.keyboardEventKeycode))" }
    return "\(event.type.rawValue)"
}
let m = InputMonitor(dryRun: true, environment: ["TYPELESS_FAKE_FRONT": app, "TYPELESS_TEST_EVENTS": path, "TYPELESS_TEST_MANUAL_SETTLE": "1", "TYPELESS_TEST_TYPELESS_PID": "42", "TYPELESS_TEST_REQUIRE_PASTE": "1"], settlementNow: { clock }, eventPoster: { route, events in
    let name: String
    switch route { case .process: name = "pid"; case .tap: name = "tap"; case .session: name = "session" }
    posts.append((name, events))
}, eventSourceFactory: { rule == "new-paste-private" ? nil : CGEventSource(event: $0) })
func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) } }
func event(_ type: CGEventType) -> CGEvent {
    if type == .keyDown || type == .keyUp { return CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: type == .keyDown)! }
    if type == .flagsChanged || type == .scrollWheel { let e = CGEvent(source: nil)!; e.type = type; return e }
    let right = [CGEventType.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type)
    return CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: right ? .right : .left)!
}
func simulated(_ type: String, _ values: [String: Any] = [:]) {
    var item = values; item["type"] = type
    var data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    data.append(try! JSONSerialization.data(withJSONObject: item)); data.append(10)
    try! data.write(to: URL(fileURLWithPath: path)); m.poll()
}
func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
func holdGesture() {
    for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
        expect(m.handleTapEvent(type, event(type), mouseTarget: .outside) == nil, "held gesture suppresses every component")
    }
}
let focus = FocusSnapshot(bundleID: app)
var authorized = true
var recordID = "first"
var recordReads = 0
if rule.hasPrefix("new-paste") { m.pasteRecordIDProvider = { recordReads += 1; return recordID } }
if rule != "prearm" && rule != "prearm-timeout" { m.armAttempt(focus: focus, authorize: { authorized }) }
if rule == "settled" || rule == "unknown-settled" {
    if rule == "unknown-settled" { simulated("capability", ["identityReadable": false]) }
    m.settleAttempt(testEvent: true)
    let down = event(.leftMouseDown)
    expect(m.handleTapEvent(.leftMouseDown, down, mouseTarget: .outside) != nil, "settled click is passed after Return")
    expect(posts.count == 1 && posts[0].0 == "tap", "settled Return must use the current callback proxy, not PID posting")
    expect(posts[0].1.map(label) == ["10:36", "11:36"], "tap injects one Return down/up pair")
} else if rule == "buffer" || rule == "claimed-end" || rule == "unknown-held" {
    for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp] {
        expect(m.handleTapEvent(type, event(type), mouseTarget: .outside) == nil, "buffered gesture and following input must be suppressed until settlement")
    }
    expect(posts.isEmpty, "no click or Return leaks before settlement")
    if rule == "unknown-held" { simulated("capability", ["identityReadable": false]) }
    m.settleAttempt(testEvent: true)
    expect(posts.count == 1 && posts[0].0 == "session" && posts[0].1.count == 1 && posts[0].1[0].type == .null, "settlement schedules only a replay carrier")
    let carrier = posts[0].1[0]
    if rule == "claimed-end" { m.onSent = { _ in
        _ = m.endAttempt()
        expect(posts.count == 2, "endAttempt during carrier callback cannot replay tail before the returned down")
    } }
    expect(m.handleTapEvent(carrier.type, carrier) != nil, "carrier is released after injecting Return")
    expect(posts.count == 2 && posts[1].0 == "tap" && posts[1].1.map(label) == ["10:36", "11:36"], "carrier callback injects Return before its returned mouseDown")
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(posts.count == 3 && posts[2].0 == "session" && posts[2].1.map(label) == ["6", "2", "10:0", "11:0"], "tail preserves drag/up/keyboard order exactly once")
}
if ["cancel", "timeout", "authorization", "permission", "stale-carrier", "new-paste", "new-paste-private", "limit"].contains(rule) {
    holdGesture()
    var stale: CGEvent?
    if rule == "stale-carrier" { m.settleAttempt(testEvent: true); stale = posts.removeFirst().1[0] }
    if rule == "cancel" || rule == "stale-carrier" { _ = m.endAttempt() }
    if rule == "timeout" { clock = 1.01; m.checkHeldInputTimeout() }
    if rule == "authorization" { authorized = false; m.settleAttempt(testEvent: true) }
    if rule == "permission" { simulated("capability", ["accessibilityTrusted": false]) }
    if rule.hasPrefix("new-paste") {
        let paste = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        paste.flags = .maskCommand; paste.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
        expect(m.isVerifiedPaste(.keyDown, paste), "fixture is a verified Typeless paste")
        expect(m.handleTapEvent(.keyDown, paste) == nil, "new paste stays behind held click while cancelling old send")
    }
    if rule == "limit" {
        for _ in 0..<253 { expect(m.handleTapEvent(.keyDown, event(.keyDown)) == nil, "bounded queue captures input through limit") }
    }
    pump()
    expect(posts.count == 1 && posts[0].0 == "session", "failure releases a single input-only batch")
    expect(posts[0].1.prefix(3).map(label) == ["1", "6", "2"], "failure preserves original gesture")
    expect(!posts[0].1.contains { $0.getIntegerValueField(.keyboardEventKeycode) == 36 && $0.type == .keyDown }, "failure never injects Return")
    for replay in posts[0].1 {
        if rule.hasPrefix("new-paste") && replay.type == .keyDown {
            _ = m.endAttempt()
            recordID = "second"
            simulated("state", ["input": "second-input", "text": ""])
        }
        expect(m.handleTapEvent(replay.type, replay) != nil, "replayed inputs bypass recapture without recursion")
    }
    if rule.hasPrefix("new-paste") {
        guard case .success(let second) = m.beginAttempt(recordID: "second") else { expect(false, "replayed Typeless paste must bind the next record"); exit(1) }
        expect(second.inputToken == "second-input", "new paste captures the actual focus at replay rather than the old pane")
        let reads = recordReads
        let replayedPaste = posts[0].1.last!
        recordID = "third"
        expect(m.handleTapEvent(replayedPaste.type, replayedPaste) != nil, "consumed paste ticket still passes physical input")
        expect(recordReads == reads, "a paste nonce captures at most once even when the callback repeats")
        if case .success = m.beginAttempt(recordID: "third") { expect(false, "repeated old paste ticket cannot bind a newer record") }
    }
    if let stale { expect(m.handleTapEvent(stale.type, stale) == nil, "stale carrier cannot release a second down") }
    m.armAttempt(focus: focus, authorize: { true }); m.settleAttempt(testEvent: true)
    if let stale { expect(m.handleTapEvent(stale.type, stale) == nil && !m.sentAwaitingReport, "old carrier cannot submit a new epoch") }
}
if rule == "prearm" || rule == "prearm-timeout" {
    simulated("typeless_paste")
    holdGesture()
    if rule == "prearm-timeout" {
        clock = 1.01; m.checkHeldInputTimeout(); pump()
        expect(posts.count == 1 && posts[0].1.map(label) == ["1", "6", "2"], "prearm without DB has an independent finite release")
        if case .success = m.beginAttempt() { expect(false, "late DB cannot revive an expired click capture") }
    } else {
        guard case .success(let f) = m.beginAttempt() else { fatalError("prearm capture missing") }
        m.armAttempt(focus: f, authorize: { true }); m.settleAttempt(testEvent: true)
        expect(posts.count == 1 && posts[0].1[0].type == .null, "matching capture adopts queue across arming: \(posts.map { ($0.0, $0.1.map(label)) })")
        let carrier = posts[0].1[0]
        expect(m.handleTapEvent(carrier.type, carrier) != nil, "prearm carrier returns saved down after Return")
        pump(); expect(posts.count == 3 && posts[2].1.map(label) == ["6", "2"], "prearm tail replays once")
    }
}
if rule == "lock" {
    holdGesture()
    let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var blockOnce = true
    // The production authorization path holds stateLock, exactly like an AX read.
    m.armAttempt(focus: focus, authorize: { if blockOnce { blockOnce = false; locked.signal(); release.wait() }; return true })
    // Re-arming invalidates the old queue; start a queue owned by this epoch.
    pump(); posts.removeAll()
    holdGesture()
    DispatchQueue.global().async { m.settleAttempt(testEvent: true); done.signal() }
    expect(locked.wait(timeout: .now() + 2) == .success, "worker owns attempt lock")
    expect(m.handleTapEvent(.leftMouseDragged, event(.leftMouseDragged)) == nil, "contended held drag remains queued")
    expect(m.handleTapEvent(.leftMouseUp, event(.leftMouseUp)) == nil, "contended held up remains queued")
    expect(m.handleTapEvent(.keyDown, event(.keyDown)) == nil, "contended following key remains queued")
    release.signal(); expect(done.wait(timeout: .now() + 2) == .success, "worker releases attempt lock")
    let carrier = posts[0].1[0]
    expect(m.handleTapEvent(carrier.type, carrier) != nil, "unchanged contended attempt still sends in carrier callback")
    pump(); expect(posts[2].1.map(label) == ["6", "2", "6", "2", "10:0"], "lock contention loses no gesture component")
}
if rule == "gesture-stream" {
    let sequence: [CGEventType] = [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .leftMouseDown, .leftMouseUp, .scrollWheel, .flagsChanged, .keyDown, .keyUp]
    for type in sequence { expect(m.handleTapEvent(type, event(type), mouseTarget: .outside) == nil, "all queued mouse/key/scroll events stay in order") }
    m.settleAttempt(testEvent: true)
    let carrier = posts[0].1[0]
    let returned = m.handleTapEvent(carrier.type, carrier)
    expect(returned?.type == .rightMouseDown && returned !== carrier, "null carrier returns a retained copy of the first physical down")
    expect(posts[1].0 == "tap" && posts[1].1.map(label) == ["10:36", "11:36"], "Return is inserted before the returned right mouseDown")
    pump()
    expect(posts[2].1.map { $0.type } == Array(sequence.dropFirst()), "multiple clicks, scroll, modifiers and keys replay in their original order")
}
if rule == "changed-held" {
    holdGesture(); m.settleAttempt(testEvent: true)
    let carrier = posts[0].1[0]
    simulated("unnotified_state", ["input": "different-input"])
    expect(m.handleTapEvent(carrier.type, carrier) != nil, "confirmed focus departure alone still sends under the requested leave policy")
    pump()
    expect(posts.count == 3 && posts[1].0 == "tap" && posts[1].1.map(label) == ["10:36", "11:36"] && posts[2].1.map(label) == ["6", "2"], "focus departure sends once then releases the original gesture")
}
if rule == "tap-disabled" {
    holdGesture()
    _ = m.handleTapEvent(.tapDisabledByTimeout, CGEvent(source: nil)!)
    pump()
    expect(posts.count == 1 && posts[0].1.map(label) == ["1", "6", "2"], "monitoring interruption releases held gesture without Return")
}
if rule == "private-marker" {
    let original = event(.keyDown)
    original.setIntegerValueField(.eventSourceUserData, value: 123)
    expect(original.getIntegerValueField(.eventSourceUserData) == 123, "fixture caches another process source metadata")
    markInputEvent(original, 456, sourceFactory: { _ in nil })
    expect(original.getIntegerValueField(.eventSourceUserData) == 456, "unavailable private source gets a new local source with the final marker")
}
if ["stale-ticket", "newer-paste-ticket", "expired-ticket", "ticket-prepare-lock"].contains(rule) {
    m.pasteRecordIDProvider = { recordID }
    holdGesture()
    let paste = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
    paste.flags = .maskCommand; paste.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
    expect(m.handleTapEvent(.keyDown, paste) == nil, "verified queued paste is retained after the held click")
    if rule == "ticket-prepare-lock" {
        let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        m.armAttempt(focus: focus, authorize: { locked.signal(); release.wait(); return false })
        m.settleAttempt(testEvent: true)
        let epoch = m.currentObservationToken!.epoch
        DispatchQueue.global().async { m.performDelivery(epoch: epoch) { _ in }; done.signal() }
        expect(locked.wait(timeout: .now() + 2) == .success, "AX/provider fixture holds attempt state during replay preparation")
        pump()
        expect(posts.count == 1, "replay ticket preparation does not wait for attempt state or query its provider")
        release.signal(); expect(done.wait(timeout: .now() + 2) == .success, "state worker releases")
        _ = m.endAttempt(); recordID = "second"; simulated("state", ["input": "second-input"])
        let replay = posts[0].1.last!
        expect(m.handleTapEvent(replay.type, replay) != nil, "paste replay remains physical input")
        guard case .success(let next) = m.beginAttempt(recordID: "second") else { fatalError("contended preparation must not discard paste ticket") }
        expect(next.inputToken == "second-input", "replay captures actual new target after state contention clears")
    } else {
        pump(); let replay = posts[0].1.last!
        _ = m.endAttempt(); recordID = "third"
        if rule == "stale-ticket" {
            m.armAttempt(focus: focus, authorize: { true })
            let token = m.currentObservationToken
            expect(m.handleTapEvent(replay.type, replay) != nil && m.currentObservationToken == token, "old ticket cannot cancel or capture into a newly armed epoch")
            if case .success = m.beginAttempt(recordID: "third") { expect(false, "old epoch ticket cannot bind a new record") }
        } else if rule == "newer-paste-ticket" {
            simulated("state", ["input": "third-input"])
            m.handleEvent(.keyDown, paste)
            expect(m.handleTapEvent(replay.type, replay) != nil, "old generation replay stays physical input")
            guard case .success(let third) = m.beginAttempt(recordID: "third") else { fatalError("newer capture must survive an old ticket") }
            expect(third.inputToken == "third-input", "old ticket cannot replace a newer paste target")
        } else {
            clock = 3
            expect(m.handleTapEvent(replay.type, replay) != nil, "expired ticket still releases user input")
            if case .success = m.beginAttempt(recordID: "third") { expect(false, "expired ticket cannot capture a newer record") }
        }
    }
}
if rule == "held-background" {
    holdGesture(); m.settleAttempt(testEvent: true)
    let carrier = posts[0].1[0]
    simulated("focus", ["app": "com.example.other"])
    expect(m.handleTapEvent(carrier.type, carrier) != nil, "background departure preserves original-PID send and releases held down")
    pump()
    expect(posts.count == 3 && posts[1].0 == "pid" && posts[1].1.map(label) == ["10:36", "11:36"] && posts[2].1.map(label) == ["6", "2"], "background Return targets saved PID before gesture replay")
}
print("click order \(rule) passed")
'''

class ClickOrderTests(unittest.TestCase):
    def test_callback_order_and_buffered_gesture(self):
        with tempfile.TemporaryDirectory(prefix="autosend-click-order-") as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text(HARNESS)
            binary = root / "click-order"
            result = subprocess.run(["swiftc", "-O", str(ROOT / "InputMonitor.swift"), str(ROOT / "PasteBaseline.swift"), str(ROOT / "Settings.swift"), str(source), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            events = root / "events.jsonl"
            events.touch()
            for rule in ("settled", "unknown-settled", "buffer", "unknown-held", "claimed-end", "cancel", "timeout", "authorization", "permission", "stale-carrier", "new-paste", "new-paste-private", "limit", "prearm", "prearm-timeout", "lock", "gesture-stream", "changed-held", "tap-disabled", "private-marker", "stale-ticket", "newer-paste-ticket", "expired-ticket", "ticket-prepare-lock", "held-background"):
                with self.subTest(rule=rule):
                    events.write_text("")
                    result = subprocess.run([binary, str(events), rule], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
