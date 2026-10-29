import Foundation

@_silgen_name("install_dictation_consumer") func installDictationConsumer()
@_silgen_name("emit_keyboard") func emitKeyboard(_ sessionOnly: Int32, _ custom: Int32)

let scenario = CommandLine.arguments.dropFirst().first ?? "fn"
if scenario == "fn" { installDictationConsumer() }
let monitor = InputMonitor(dryRun: false, environment: [:])
var cancellationReasons: [String] = []
monitor.onKeyboard = { cancellationReasons.append($0) }
if scenario == "consumer-after-daemon" { installDictationConsumer() }
guard case .success(let focus) = monitor.beginAttempt() else {
    fputs("fixture error: public beginAttempt failed\n", stderr)
    exit(2)
}
monitor.armAttempt(focus: focus)
emitKeyboard(0, 0)
if cancellationReasons.isEmpty {
    fputs("FAIL: \(scenario): starting Fn dictation must cancel a pending send even when the dictation consumer swallows the shortcut before session delivery\n", stderr)
    exit(1)
}
print("PASS: \(scenario): swallowed Fn dictation shortcut cancels the pending send")
