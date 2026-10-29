import Foundation

@_silgen_name("emit_consumed_dictation_fn")
func emitConsumedDictationFn()

let monitor = InputMonitor(dryRun: false, environment: [:])
var cancellationReasons: [String] = []
monitor.onKeyboard = { cancellationReasons.append($0) }
monitor.armAttempt(focus: FocusSnapshot(bundleID: "com.test.editor"))
emitConsumedDictationFn()
if cancellationReasons.isEmpty {
    fputs("FAIL: starting Fn dictation must cancel a pending send even when the dictation consumer swallows the shortcut before session delivery\n", stderr)
    exit(1)
}
print("PASS: swallowed Fn dictation shortcut cancels the pending send")
