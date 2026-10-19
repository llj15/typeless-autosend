# Typeless AutoSend

A macOS command-line utility and login service for Apple Silicon (ARM). After Typeless finishes a transcription, it waits before pressing Return in an application you explicitly enabled. Any user keystroke or change of input focus cancels the pending send.

## Install

Prerequisites: Typeless installed and signed in, history enabled, and Xcode Command Line Tools (`xcode-select --install`). This release targets macOS on Apple Silicon; Windows is not supported.

Keep the repository in an unprotected directory, for example `~/Developer/typeless-autosend`. Do not install from Desktop, Documents, Downloads, or iCloud: the background service cannot read its files there.

```bash
git clone https://github.com/llj15/typeless-autosend.git ~/Developer/typeless-autosend
cd ~/Developer/typeless-autosend
./install.sh
```

The installer builds the native executable, registers a login LaunchAgent, and links `~/.local/bin/typeless-autosend`. If necessary it adds a marked PATH block to your zsh or bash startup file. Open a new terminal after installing. Other shells receive a manual PATH instruction.

On the first service start after each install, the program requests Accessibility if needed. Later service restarts do not repeat the request. The installer opens System Settings → Privacy & Security → Accessibility; enable the executable printed by the installer, then run the printed service restart command to refresh its permission state. Accessibility provides the event access needed by this tool, so installation does not request separate Input Monitoring permission. If Settings cannot be opened, installation still finishes and prints the manual path. A rebuild can invalidate permission: remove the stale entry and add the rebuilt executable again.

Fresh installations enable **no apps**. Upgrades leave your existing configuration intact. The program, config and log remain in the repository directory. After moving it, run `./install.sh` again to update the service and command link.

## Choose applications

```bash
typeless-autosend apps search Ghostty
typeless-autosend apps add com.mitchellh.ghostty
typeless-autosend apps list
typeless-autosend apps remove com.mitchellh.ghostty
```

Search includes installed applications that are not running. Results contain the app name and Bundle ID. **`apps add` only accepts a Bundle ID**, not an application name. Adding enables the app immediately; removing disables it and removes its delay override. There is no per-app disable switch.

## Configure the delay

```bash
typeless-autosend delay get
typeless-autosend delay set 2
typeless-autosend delay set 0.5 --app com.mitchellh.ghostty
typeless-autosend delay get --app com.mitchellh.ghostty
typeless-autosend delay reset --app com.mitchellh.ghostty
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

Typeless-generated input is excluded only when it can be attributed to Typeless. Unattributed keyboard events cancel conservatively. Application Accessibility support varies; terminal editors or custom controls may not expose the caret information required to enable automatic sending. Redundant Accessibility focus notifications do not cancel when both the notified target and the current focus match the original target. A notification identifying another target still cancels, even if focus has already returned; unreadable focus also cancels.

## Pause and inspect

```bash
typeless-autosend service pause
typeless-autosend service resume
typeless-autosend service status
typeless-autosend doctor
```

Pause survives restarts and login; resume explicitly to enable sending again. Transcriptions completed before that resume are not replayed, even if the service was briefly stalled during the pause. Pausing or removing the pending app cancels its countdown. Changing a delay affects subsequent transcriptions only. Status includes the latest skip reason when runtime information is available.

An observed input-listener interruption cancels the current countdown permanently. While permissions allow it and Secure Input is off, the service tries to re-enable or recreate the listener at most once per second. Recovery does not replay transcriptions completed at or before that recovery; only later completions can schedule a new countdown. Unavailable event-listening access and Secure Input keep sending disabled without repeatedly rebuilding the listener.

`service status` includes the listener's reason, permission, Secure Input, event tap and run-loop-source states, recovery count and latest recovery time. `doctor` fails when listener status is unavailable, missing or stale instead of reporting “All good”. If permissions were granted but the listener remains unavailable, restart the existing service with `launchctl kickstart -k gui/$(id -u)/local.typeless-autosend`, then check status again. Logs record observed listener state changes; they do not identify unobserved OS permission changes as a proven cause.

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

Use `--help` for commands and `--json` or `--format json` for structured output. Noninteractive output defaults to JSON. `apps add --if-not-exists` and `apps remove --if-exists` allow safe repetition. `schema` describes the command interface. The older `list-apps [--all]` command still lists running apps for compatibility.

Exit codes: 0 success, 1 general/config error, 2 invalid arguments, 3 not found, 4 permission denied, 5 conflict. Diagnostics go to stderr; command data goes to stdout. Legacy `doctor` and `list-apps` retain their original text output.

## Tests

```bash
tests/run.sh
```

Tests compile a separate executable and use temporary SQLite databases, simulated system events and dry-run sends. Installer tests use a sandboxed HOME and stub system commands. They do not install the actual service or press Return in real applications. The tests validate the CLI, daemon behavior and installer boundaries; they do not certify Accessibility behavior in every real application.

## Upgrade and uninstall

Update the source and rerun `./install.sh` in the existing installation directory. Reauthorize the rebuilt executable as described above.

Upgrading from **typeless-autoenter** keeps `config.json` unchanged, including enabled apps, pause state, delays, overrides and cancellation revisions. The installer stops and checks the old `local.typeless-autoenter` service before starting `local.typeless-autosend`, removes the old LaunchAgent and its owned command link, and installs `typeless-autosend`. It migrates the shell PATH marker and writes new logs to `autosend.log`; old `autoenter.log` files remain available. If the old service cannot be stopped, the upgrade aborts before starting a new service.

The installation directory may keep its old name. To rename it, move the **whole existing directory** and rerun `./install.sh`; do not install a separate checkout over a live installation. The existing instance lock and all configuration stay together. Update an existing clone's remote URL with `git remote set-url origin https://github.com/llj15/typeless-autosend.git`.

For scripts, `TYPELESS_AUTOSEND_CONFIG` overrides the config path. The legacy `TYPELESS_AUTOENTER_CONFIG` remains a fallback; the new variable wins if both are set.

```bash
./uninstall.sh
```

Uninstall stops both current and legacy service names, removes their LaunchAgents and removes their owned command links. It preserves the repository, configuration and shared PATH block. Remove the Accessibility entry manually if no longer needed.
