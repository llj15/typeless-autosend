"""Pure AX ancestry and focus-departure decisions; no system event delivery."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class FocusRelationship(unittest.TestCase):
    def test_focus_within_original_input_is_not_departure(self):
        with tempfile.TemporaryDirectory(prefix="autosend-focus-relation-") as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text(r'''
import Foundation

let original = FocusSnapshot(bundleID: "com.example.editor", processID: 4242,
                             windowToken: "original-window", inputToken: "input-1")
let parents = [1: 2, 2: 10, 3: 10, 4: 1]
func relation(_ hit: Int) -> InputTargetRelation {
    InputMonitor.classifyFocusedInputTarget(focused: hit, original: 1, equal: ==, parentStep: { element in
        if element == 10 { return .boundary }
        if let parent = parents[element] { return .parent(parent) }
        return .unavailable
    })
}
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
for hit in [1, 2, 4] {
    var focused = original
    focused.inputToken = "input-\(hit)"
    expect(relation(hit) == .inside, "fixture stays in the original input hierarchy")
    expect(!InputMonitor.focusHasDeparted(original: original, focused: focused, inputRelation: relation(hit)),
           "original input or its AX ancestor/child preserves countdown")
}
var sibling = original
sibling.inputToken = "input-3"
expect(InputMonitor.focusHasDeparted(original: original, focused: sibling, inputRelation: relation(3)),
       "separate same-window input is departure")
expect(!InputMonitor.focusHasDeparted(original: original, focused: sibling, inputRelation: .unknown),
       "unreadable ancestry alone cannot prove same-window departure")
var container = original
container.inputToken = "window-container"
expect(relation(10) == .outside, "a focus notification naming the window is an explicit departure")
expect(InputMonitor.focusHasDeparted(original: original, focused: container, inputRelation: relation(10)),
       "focus on the window container is not a descendant inside the original input")
var window = original
window.windowToken = "other-window"
expect(InputMonitor.focusHasDeparted(original: original, focused: window, inputRelation: .inside),
       "a different window is departure even if input identity is retained")
expect(InputMonitor.focusHasDeparted(original: original, focused: window, inputRelation: .unknown),
       "a confirmed window switch does not depend on input ancestry")
var process = original
process.processID = 4343
expect(InputMonitor.focusHasDeparted(original: original, focused: process, inputRelation: .inside),
       "a different process cannot be inside the original window")
print("focus relationship checks passed")
''')
            binary = root / "focus-relationship"
            compiled = subprocess.run([
                "swiftc", "-O", str(ROOT / "InputMonitor.swift"),
                str(ROOT / "PasteBaseline.swift"), str(ROOT / "Settings.swift"),
                str(source), "-o", str(binary),
            ], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
