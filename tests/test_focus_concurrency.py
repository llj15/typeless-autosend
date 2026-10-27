"""Exercise the production monitor's send/cancel lock with real concurrent threads.

Dry-run constructs CGEvents but never posts them or requests macOS permission.
This does not simulate AX compatibility or native event routing.
"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class FocusConcurrency(unittest.TestCase):
    def test_send_and_cancel_have_one_atomic_outcome(self):
        with tempfile.TemporaryDirectory(prefix="autosend-focus-race-") as directory:
            root = Path(directory)
            (root / "main.swift").write_text(r'''
import Foundation
import ApplicationServices

final class Results {
    let lock = NSLock()
    var delivered: [Int: Bool] = [:]
    var outcomes: [Int: Bool] = [:]
    func record(_ index: Int, delivered value: Bool) {
        lock.lock(); defer { lock.unlock() }
        delivered[index] = value
    }
    func record(_ index: Int, outcome value: Bool) {
        lock.lock(); defer { lock.unlock() }
        outcomes[index] = value
    }
}
let results = Results()
let trials = 1000
for index in 0..<trials {
    let monitor = InputMonitor(dryRun: true, environment: ["TYPELESS_FAKE_FRONT": "com.example.editor"])
    let focus = FocusSnapshot(bundleID: "com.example.editor")
    monitor.armAttempt(focus: focus, authorize: { true })
    monitor.settleAttempt()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        monitor.deliver { results.record(index, delivered: $0) }
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        results.record(index, outcome: monitor.endAttempt() != nil)
        group.leave()
    }
    group.wait()
}
let deadline = Date().addingTimeInterval(10)
while results.delivered.count < trials && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
var mismatches = 0
for index in 0..<trials {
    if results.delivered[index] == nil || results.delivered[index] != results.outcomes[index] { mismatches += 1 }
}
print(String(data: try! JSONSerialization.data(withJSONObject: ["trials": trials, "mismatches": mismatches]), encoding: .utf8)!)
exit(mismatches == 0 ? 0 : 1)
''')
            binary = root / "focus-race"
            compile_result = subprocess.run(["swiftc", "-O", str(ROOT / "InputMonitor.swift"),
                str(ROOT / "PasteBaseline.swift"),
                str(ROOT / "Settings.swift"), str(root / "main.swift"), "-o", str(binary)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), {"trials": 1000, "mismatches": 0})


if __name__ == "__main__":
    unittest.main()
