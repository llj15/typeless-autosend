"""Native-style deferred cancellation reporting, using simulated input only."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class AttemptOutcome(unittest.TestCase):
    def test_first_reason_survives_polling_before_deferred_report(self):
        with tempfile.TemporaryDirectory(prefix="autosend-outcome-") as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text(r'''
import Foundation

let events = CommandLine.arguments[1]
let rule = CommandLine.arguments[2]
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func event(_ monitor: InputMonitor, _ type: String, _ fields: [String: Any] = [:]) {
    let data = try! JSONSerialization.data(withJSONObject: fields.merging(["type": type]) { _, new in new })
    let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: events))
    try! file.seekToEnd(); try! file.write(contentsOf: data + Data([10])); try! file.close()
    monitor.poll()
}
try! Data().write(to: URL(fileURLWithPath: events))
let monitor = InputMonitor(dryRun: true, environment: ["TYPELESS_TEST_EVENTS": events,
    "TYPELESS_FAKE_FRONT": "com.example.editor", "TYPELESS_TEST_DEFER_CANCEL_REPORT": "1"])
func arm() {
    event(monitor, "state", ["text": "hello", "caret": 5, "selectionLength": 0])
    guard case .success(let focus) = monitor.beginAttempt() else { fatalError("focus") }
    monitor.armAttempt(focus: focus, authorize: { true })
    monitor.settleAttempt()
}
var reports: [String] = []
monitor.onKeyboard = { reports.append($0) }
if rule == "sent" {
    arm()
    event(monitor, "transition")
    let outcome = monitor.endAttemptOutcome()
    expect(outcome.sentReason == "before-focus-change", "successful send retains destination")
    expect(outcome.cancellationReason == nil, "send does not invent cancellation")
} else {
    if rule == "buffer-content" {
        event(monitor, "state", ["text": "draft ", "caret": 6])
        event(monitor, "typeless_paste")
        event(monitor, "state", ["text": "draft hello!", "caret": 12])
        guard case .success(let focus) = monitor.beginAttempt() else { fatalError("buffer focus") }
        monitor.armAttempt(focus: focus, pastedText: "hello", authorize: { true })
        monitor.settleAttempt()
    } else {
        arm()
        event(monitor, "unnotified_state", rule.hasPrefix("caret") ? ["caret": 2] : ["text": "hello!"])
        _ = monitor.validateAttempt()
    }
    expect(reports.isEmpty, "native-style cancellation report is deferred")
    let expectedKind = rule.hasPrefix("caret") ? "caret" : "content"
    guard case .failure(let failure) = monitor.validateAttempt() else { fatalError("cancelled validation") }
    expect(failure.reason.contains("kind=\(expectedKind)"), "poll before report preserves concrete first reason")
    expect(!failure.reason.contains("hello"), "diagnostics do not contain input text")
    if rule.hasSuffix("callback-first") {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        expect(reports.count == 1 && reports[0] == failure.reason, "callback reports the same first cause once")
    }
    let outcome = monitor.endAttemptOutcome()
    expect(outcome.sentReason == nil, "cancelled attempt never reports a send")
    expect(outcome.cancellationReason == failure.reason, "atomic outcome overrides consumer fallback with first cause")
    let again = monitor.endAttemptOutcome()
    expect(again.sentReason == nil && again.cancellationReason == nil, "outcome is consumed only once")
    arm()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    expect(reports.count == (rule.hasSuffix("callback-first") ? 1 : 0), "old queued report cannot cancel or report against new epoch")
    if case .failure = monitor.validateAttempt() { fatalError("new attempt inherited old cancellation") }
    let fresh = monitor.endAttemptOutcome()
    expect(fresh.cancellationReason == nil, "new attempt starts without the old reason")
}
print("attempt outcome checks passed")
''')
            binary = root / "attempt-outcome"
            dependencies = [ROOT / name for name in [
                "InputMonitor.swift", "PasteBaseline.swift", "Settings.swift",
                "ClickOrderController.swift",
            ] if (ROOT / name).exists()]
            compiled = subprocess.run(["swiftc", "-O", *map(str, dependencies), str(source),
                                       "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            for rule in ["content", "caret", "buffer-content", "content-callback-first",
                         "caret-callback-first", "sent"]:
                with self.subTest(rule=rule):
                    result = subprocess.run([binary, str(root / "events.jsonl"), rule],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
