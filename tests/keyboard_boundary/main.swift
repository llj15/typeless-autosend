import Foundation

@_silgen_name("install_dictation_consumer") func installDictationConsumer()
@_silgen_name("set_hid_creation_failure") func setHIDCreationFailure(_ fail: Int32)
@_silgen_name("interrupt_listener") func interruptListener(_ hid: Int32, _ invalidate: Int32)
@_silgen_name("emit_keyboard") func emitKeyboard(_ sessionOnly: Int32, _ custom: Int32)

let scenario = CommandLine.arguments.dropFirst().first ?? "fn"
if scenario == "fn" || scenario == "custom" { installDictationConsumer() }
if scenario == "hid-create-failure" { setHIDCreationFailure(1) }
let monitor = InputMonitor(dryRun: false, environment: [:])
if scenario == "hid-create-failure" {
    guard !monitor.available, case .failure = monitor.beginAttempt() else {
        fputs("FAIL: unavailable HID listener must prevent sending\n", stderr); exit(1)
    }
    setHIDCreationFailure(0)
    let recoveryDeadline = Date().addingTimeInterval(2)
    repeat {
        monitor.poll()
        if !monitor.available { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    } while !monitor.available && Date() < recoveryDeadline
    guard monitor.available else { fputs("FAIL: HID listener must recover\n", stderr); exit(1) }
    print("PASS: HID creation failure blocks sending and recovers")
    exit(0)
}
var cancellationReasons: [String] = []
monitor.onKeyboard = { cancellationReasons.append($0) }
if scenario == "consumer-after-daemon" { installDictationConsumer() }
guard case .success(let focus) = monitor.beginAttempt() else {
    fputs("fixture error: public beginAttempt failed\n", stderr)
    exit(2)
}
monitor.armAttempt(focus: focus)
if scenario == "consumer-after-arm" {
    installDictationConsumer()
    emitKeyboard(0, 0)
    guard !monitor.available else {
        fputs("FAIL: persistent dictation consumer installed during countdown must block unsafe sending\n", stderr); exit(1)
    }
    monitor.poll()
    guard !cancellationReasons.isEmpty else {
        fputs("FAIL: changed shortcut routing must notify cancellation of the old attempt\n", stderr); exit(1)
    }
    print("PASS: restarted dictation consumer during countdown cancels the old attempt")
    exit(0)
}
if scenario.hasSuffix("timeout") || scenario.hasSuffix("invalid") {
    let invalid = scenario.hasSuffix("invalid")
    interruptListener(scenario.hasPrefix("hid") ? 1 : 0, invalid ? 1 : 0)
    guard !monitor.available else { fputs("FAIL: listener interruption must block sending\n", stderr); exit(1) }
    if !invalid && cancellationReasons.isEmpty {
        fputs("FAIL: listener timeout must immediately cancel pending send\n", stderr); exit(1)
    }
    monitor.poll()
    guard monitor.available && !cancellationReasons.isEmpty else {
        fputs("FAIL: listener recovery must cancel the old attempt and restore monitoring\n", stderr); exit(1)
    }
    print("PASS: \(scenario): interruption cancels old attempt and monitoring recovers")
    exit(0)
}
emitKeyboard(scenario == "session" ? 1 : 0, scenario == "custom" ? 1 : 0)
if cancellationReasons.isEmpty {
    fputs("FAIL: \(scenario): keyboard input must cancel the pending send through production event routing\n", stderr)
    exit(1)
}
print("PASS: \(scenario): keyboard activity cancels the pending send")
