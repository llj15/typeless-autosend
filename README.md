# typeless-autoenter

A macOS command-line utility and login service for Apple Silicon (ARM). After Typeless finishes a transcription, it waits before pressing Return in an application you explicitly enabled. Any user keystroke or change of input focus cancels the pending send.

## Install

Prerequisites: Typeless installed and signed in, history enabled, and Xcode Command Line Tools (`xcode-select --install`). This release targets macOS on Apple Silicon; Windows is not supported.

Keep the repository in an unprotected directory, for example `~/Developer/typeless-autoenter`. Do not install from Desktop, Documents, Downloads, or iCloud: the background service cannot read its files there.

```bash
./install.sh
```

The installer builds the native executable, registers a login LaunchAgent, and links `~/.local/bin/typeless-autoenter`. If necessary it adds a marked PATH block to your zsh or bash startup file. Open a new terminal after installing. Other shells receive a manual PATH instruction.

Grant the executable Accessibility permission in System Settings → Privacy & Security → Accessibility. The service also needs permission to observe input events: check System Settings → Privacy & Security → Input Monitoring if its diagnostics report input monitoring unavailable. A rebuild can invalidate permissions: remove the old Accessibility entry and add the rebuilt executable again.

Fresh installations enable **no apps**. Upgrades leave your existing configuration intact. The program, config and log remain in the repository directory. After moving it, run `./install.sh` again to update the service and command link.

## Choose applications

```bash
typeless-autoenter apps search Ghostty
typeless-autoenter apps add com.mitchellh.ghostty
typeless-autoenter apps list
typeless-autoenter apps remove com.mitchellh.ghostty
```

Search includes installed applications that are not running. Results contain the app name and Bundle ID. **`apps add` only accepts a Bundle ID**, not an application name. Adding enables the app immediately; removing disables it and removes its delay override. There is no per-app disable switch.

## Configure the delay

```bash
typeless-autoenter delay get
typeless-autoenter delay set 2
typeless-autoenter delay set 0.5 --app com.mitchellh.ghostty
typeless-autoenter delay get --app com.mitchellh.ghostty
typeless-autoenter delay reset --app com.mitchellh.ghostty
```

The default delay is **1 second**. Nonnegative fractional seconds are supported. An app override takes precedence; resetting it makes that app follow the global value again. Global `delay reset` restores 1 second.

A fixed 150 ms paste buffer comes before the configured delay. A value of `0` removes the extra waiting period, not that buffer. Timing starts when the database completion is detected; Typeless has no official completion hook and this is not proof that pasting has finished.

## Cancellation rules

During the wait:

- Every real key press, including Fn and modifier keys, cancels this send permanently.
- Switching applications, windows or input controls cancels it, even if the new application is also enabled.
- A mouse click cancels it when the click changes the caret, selection or input focus. Clicking the same position without changing any of those does not cancel it. Moving the mouse or scrolling alone does not cancel it.
- Starting another dictation with Fn cancels the old send immediately. When a new transcription completes, a new countdown can start; canceling or failing the dictation does not send the old text.
- Cancellation is permanent for that attempt: returning focus or stopping typing does not restart it. Send manually or finish a new transcription.
- If reliable focus/input inspection is unavailable, the service skips this attempt, records a reason, and checks again on the next transcription.

Typeless-generated input is excluded only when it can be attributed to Typeless. Unattributed keyboard events cancel conservatively. Application Accessibility support varies; terminal editors or custom controls may not expose the caret information required to enable automatic sending. Redundant or ambiguous Accessibility focus notifications are treated conservatively: even an apparently unchanged click can cancel if the app does not provide enough information to rule out an intervening focus change.

## Pause and inspect

```bash
typeless-autoenter service pause
typeless-autoenter service resume
typeless-autoenter service status
typeless-autoenter doctor
```

Pause survives restarts and login; resume explicitly to enable sending again. Transcriptions completed before that resume are not replayed, even if the service was briefly stalled during the pause. Pausing or removing the pending app cancels its countdown. Changing a delay affects subsequent transcriptions only. Status includes the latest skip reason when runtime information is available.

## Configuration and scripting

Commands update the sibling `config.json` atomically. Existing apps-only configurations are supported and unknown fields are preserved. The service reloads settings without a restart. Use the CLI for cancellation guarantees: pause and removal commands leave a durable cancellation revision even if immediately reversed. Direct hand-edits are sampled approximately every 100 ms, so intermediate edits that are reverted before the next sample cannot be guaranteed to cancel a countdown.

```json
{
  "apps": ["com.mitchellh.ghostty"],
  "delaySeconds": 1,
  "appDelaySeconds": {"com.mitchellh.ghostty": 2},
  "paused": false
}
```

Use `--help` for commands and `--json` or `--format json` for structured output. Noninteractive output defaults to JSON. Mutation commands support `--dry-run` (preview only, exit 10). `apps add --if-not-exists` and `apps remove --if-exists` allow safe repetition. `schema` describes the command interface. The older `list-apps [--all]` command still lists running apps for compatibility.

Exit codes: 0 success, 1 general/config error, 2 invalid arguments, 3 not found, 4 permission denied, 5 conflict, 10 successful dry-run. Diagnostics go to stderr; command data goes to stdout. Legacy `doctor` and `list-apps` retain their original text output.

## Tests

```bash
tests/run.sh
```

Tests compile a separate executable and use temporary SQLite databases, simulated system events and dry-run sends. Installer tests use a sandboxed HOME and stub system commands. They do not install the actual service or press Return in real applications. The tests validate the CLI, daemon behavior and installer boundaries; they do not certify Accessibility behavior in every real application.

## Upgrade and uninstall

Update the source and rerun `./install.sh`. Reauthorize the rebuilt executable as described above.

```bash
./uninstall.sh
```

Uninstall stops the service, removes its LaunchAgent and removes its own command link. It preserves the repository, configuration and shared PATH block. Remove the Accessibility entry manually if no longer needed.
