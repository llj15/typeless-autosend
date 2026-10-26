"""Original-input editing versus selection changes caused by losing focus."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class DepartureContext(unittest.TestCase):
    def test_blur_does_not_turn_departure_into_caret_edit(self):
        with tempfile.TemporaryDirectory(prefix="autosend-departure-context-") as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text(r'''
import Foundation

let events = CommandLine.arguments[1]
let rule = CommandLine.arguments[2]
let app = "com.example.editor"
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func event(_ monitor: InputMonitor, _ type: String, _ fields: [String: Any] = [:]) {
    let data = try! JSONSerialization.data(withJSONObject: fields.merging(["type": type]) { _, new in new })
    let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: events))
    try! file.seekToEnd(); try! file.write(contentsOf: data + Data([10])); try! file.close()
    monitor.poll()
}
func make() -> InputMonitor {
    try! Data().write(to: URL(fileURLWithPath: events))
    return InputMonitor(dryRun: true, environment: ["TYPELESS_TEST_EVENTS": events, "TYPELESS_FAKE_FRONT": app])
}
func arm(_ monitor: InputMonitor, caret: Int = 5) {
    event(monitor, "state", ["text": "hello", "caret": caret])
    guard case .success(let focus) = monitor.beginAttempt() else { fatalError("original focus") }
    monitor.armAttempt(focus: focus, authorize: { true }); monitor.settleAttempt()
}
// Focus already on another composer of the same application would receive a
// late Return, so the attempt ends; the blur's caret reset is not reported as an edit.
func expectDepartureCancel(_ monitor: InputMonitor, _ reason: String, _ label: String) {
    expect(!monitor.sentAwaitingReport, "\(label): Return is not sent to the newly focused composer")
    expect(reason.contains(InputMonitor.sameApplicationDepartureReason), "\(label): cancellation names the departure")
    expect(!reason.contains("kind="), "\(label): blur reset is not reported as an edit")
}
if rule == "settled-blur" {
    let monitor = make(); arm(monitor)
    var reason = ""
    monitor.onKeyboard = { reason = $0 }
    event(monitor, "unnotified_state", ["caret": 0])
    event(monitor, "focus", ["input": "message-editor", "text": "other input", "caret": 0])
    expectDepartureCancel(monitor, reason, "observed composer departure")
}
if rule == "notified-blur" {
    let monitor = make(); arm(monitor)
    var reason = ""
    monitor.onKeyboard = { reason = $0 }
    event(monitor, "unnotified_state", ["caret": 0])
    event(monitor, "focus_notification", ["input": "message-editor"])
    expectDepartureCancel(monitor, reason, "notified composer departure")
}
if rule == "prearm-return-click" {
    let monitor = make()
    event(monitor, "state", ["text": "> ", "caret": 2])
    event(monitor, "typeless_paste")
    event(monitor, "state", ["text": "> hello", "caret": 7])
    event(monitor, "deactivate")
    // The app has returned, but its focused-element identity is still cached.
    event(monitor, "unnotified_state", ["caret": 0])
    event(monitor, "transition")
    guard case .success(let focus) = monitor.beginAttempt() else { fatalError("prearm return focus") }
    monitor.armAttempt(focus: focus, pastedText: "hello", authorize: { true })
    monitor.settleAttempt()
    expect(monitor.sentAwaitingReport, "later prearm click must retain the previously confirmed focus loss")
}
if rule == "refresh-without-paste" {
    var now: TimeInterval = 0
    try! Data().write(to: URL(fileURLWithPath: events))
    let monitor = InputMonitor(dryRun: true, environment: ["TYPELESS_TEST_EVENTS": events,
        "TYPELESS_FAKE_FRONT": app, "TYPELESS_TEST_MANUAL_SETTLE": "1"], settlementNow: { now })
    event(monitor, "state", ["text": "old history\n> ", "selectionAvailable": false])
    event(monitor, "typeless_paste")
    event(monitor, "state", ["text": "new history\n> "])
    guard case .success(let focus) = monitor.beginAttempt() else { fatalError("refresh capture") }
    monitor.armAttempt(focus: focus, pastedText: "hello", authorize: { true })
    monitor.settleAttempt(testEvent: true)
    event(monitor, "deactivate")
    expect(!monitor.sentAwaitingReport, "unrelated output refresh must not establish a paste or send")
    now = 1.1
    monitor.settleAttempt(testEvent: true)
    expect(!monitor.sentAwaitingReport, "absence of pasted text after bounded wait never sends")
}
if rule == "buffer-blur" || rule == "notified-buffer-blur" {
    let monitor = make()
    event(monitor, "state", ["text": "> ", "caret": 2])
    event(monitor, "typeless_paste")
    event(monitor, "state", ["text": "> hello", "caret": 7])
    guard case .success(let focus) = monitor.beginAttempt() else { fatalError("buffer focus") }
    monitor.armAttempt(focus: focus, pastedText: "hello", authorize: { true })
    var reason = ""
    monitor.onKeyboard = { reason = $0 }
    event(monitor, "unnotified_state", ["caret": 0])
    if rule == "buffer-blur" {
        event(monitor, "focus", ["input": "message-editor", "text": "other input", "caret": 0])
    } else {
        event(monitor, "focus_notification", ["input": "message-editor"])
    }
    expect(!monitor.sentAwaitingReport, "buffer composer departure never sends before settlement")
    monitor.settleAttempt()
    expectDepartureCancel(monitor, reason, "buffered composer departure")
}
for field in rule == "real-edits" ? ["caret", "text", "selection"] : [] {
    let monitor = make(); arm(monitor, caret: field == "selection" ? 0 : 5)
    var reason = ""
    monitor.onKeyboard = { reason = $0 }
    let fields: [String: Any] = field == "caret" ? ["caret": 0] :
        (field == "selection" ? ["selectionLength": 1] : ["text": "hello!"])
    event(monitor, "unnotified_state", fields)
    if field != "text" {
        event(monitor, "transition") // Still before the click changes focus.
    } else {
        event(monitor, "focus", ["input": "message-editor", "text": "other input"])
    }
    expect(!monitor.sentAwaitingReport, "confirmed original \(field) editing still cancels")
    expect(!reason.isEmpty, "confirmed editing reports a reason")
    expect(reason.contains("kind=\(field == "text" ? "content" : field)"), "diagnostics distinguish the actual edit criterion")
    expect(reason.contains("app=\(app)"), "diagnostics identify the original application")
    expect(!reason.contains("hello"), "diagnostics do not include input contents")
}
print("departure context checks passed")
''')
            binary = root / "departure-context"
            compiled = subprocess.run([
                "swiftc", "-O", str(ROOT / "InputMonitor.swift"),
                str(ROOT / "PasteBaseline.swift"), str(ROOT / "Settings.swift"),
                str(source), "-o", str(binary),
            ], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            (root / "events.jsonl").touch()
            for rule in ["settled-blur", "notified-blur", "buffer-blur", "notified-buffer-blur", "prearm-return-click", "refresh-without-paste", "real-edits"]:
                with self.subTest(rule=rule):
                    result = subprocess.run([binary, str(root / "events.jsonl"), rule],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
