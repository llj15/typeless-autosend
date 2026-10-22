# Typeless AutoSend

A macOS command-line utility and login service for Apple Silicon (ARM). After Typeless finishes a transcription, it waits before pressing Return in an application you explicitly enabled. A pending send follows the original input across application switches, with conservative checks before sending.

## Install from a Release (recommended)

Requires **macOS 15 or later on Apple Silicon (ARM64)**, with Typeless installed, signed in, and history enabled. Swift, Xcode, Node.js and npm are not needed.

Download the `typeless-autosend-v1.1.0-macos-arm64.tar.gz` asset from [GitHub Releases](https://github.com/llj15/typeless-autosend/releases/latest). Choose the binary archive, not GitHub's generated **Source code** archives.

```bash
tar -xzf typeless-autosend-v1.1.0-macos-arm64.tar.gz
cd typeless-autosend-v1.1.0-macos-arm64
./install.sh
```

The Release installer verifies the bundled checksums and installs the precompiled executable in `~/typeless-autosend`. An existing registered installation is upgraded in its original directory, preserving `config.json` byte for byte. You can extract the archive in Downloads and delete it after installation: the service uses the installed copy.

The installer registers a login LaunchAgent and links `~/.local/bin/typeless-autosend`. If necessary it adds a marked PATH block to your zsh or bash startup file. Open a new terminal after installing. Other shells receive a manual PATH instruction. The binary is ad-hoc signed, without Developer ID signing or notarization; follow macOS's approval flow if it blocks downloaded files.

## Build and install from source

Source installation additionally requires Xcode Command Line Tools (`xcode-select --install`).

Keep the repository in an unprotected directory, for example `~/Developer/typeless-autosend`. Do not install from Desktop, Documents, Downloads, or iCloud: the background service cannot read its files there.

```bash
git clone https://github.com/llj15/typeless-autosend.git ~/Developer/typeless-autosend
cd ~/Developer/typeless-autosend
./install.sh
```

The source installer compiles the native executable and runs it from the repository directory. After moving a source installation, rerun `./install.sh` there to update its service and command link.

## Grant Accessibility

On the first service start after each install, the program requests Accessibility if needed. Later service restarts do not repeat the request. The installer runs `doctor` automatically and opens System Settings → Privacy & Security → Accessibility only when it reports missing Accessibility or input-listening permission. If checks pass, no permission setup is needed. Other check failures retain their diagnostics without opening Settings. When authorization is needed, remove the existing typeless-autosend entry with − (skip removal if there is no entry), click + to add the current executable printed by the installer, and turn on its switch. Then run the printed service restart command and `typeless-autosend doctor`; `All good` means setup is complete. Accessibility provides the event access needed by this tool, so installation does not request separate Input Monitoring permission. If Settings cannot be opened, installation still finishes and prints the manual path. A rebuild can invalidate permission.

Fresh installations enable **no apps**. Upgrades leave your existing configuration intact. The program, config and log remain together in the installation directory. The Release installer also copies the uninstall script, AI usage skill (`skill/SKILL.md`), and version/source information (`BUILD_INFO`) there.

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
typeless-autosend delay get --all
typeless-autosend delay set 2
typeless-autosend delay set 0.5 --app com.mitchellh.ghostty
typeless-autosend delay get --app com.mitchellh.ghostty
typeless-autosend delay reset --app com.mitchellh.ghostty
```

The default delay is **1 second**. Nonnegative fractional seconds are supported. An app override takes precedence; resetting it makes that app follow the global value again. Global `delay reset` restores 1 second.

A fixed 150 ms paste buffer comes before the configured delay. A value of `0` removes the extra waiting period, not that buffer. Timing starts when the database completion is detected; Typeless has no official completion hook and this is not proof that pasting has finished.

## Focus changes and cancellation

These rules apply only after a new Typeless completion schedules an automatic send in an enabled application. Ordinary typing without a pending send never causes Return.

- Switching to another application keeps the original deadline. At expiry the service checks the original application's PID, AX window, input object, text and selection, then posts Return to that PID without activating it. Keys and text edits in the other application do not cancel the original send.
- While the original application is still frontmost, a verified left click on a distinct, enabled text field or text area can send before the original click is released. Both controls must have separate Accessibility ancestry ending in a window, and the target must support focus. This also covers another window in the same application when those checks succeed. There is no focus restoration or fixed waiting period.
- Plain, non-repeated Tab can send first only from an Accessibility single-line `AXTextField` with an ASCII-capable keyboard input source. Multiline/custom editors, IME input sources, modified Tab and uncertain navigation cancel conservatively. Applications can customize Tab behavior; this restricted classification is not a compatibility guarantee.
- Clicking the original input, buttons, combo boxes, ambiguous composite controls, or an unreadable target cancels. Activating the original application from another application keeps the deadline rather than injecting Return ahead of activation. Programmatic focus changes without a verified intercepted input event cancel.
- Editing the original input, moving its caret or changing its selection cancels permanently. Physical editing keys, Return/newline, modified navigation and Fn also cancel while the original application is frontmost. Modifier changes alone do not edit text; Command-Tab preserves the countdown.
- The existing 150 ms paste buffer must finish before an early send is allowed. During it, attributed Typeless paste changes can settle; user editing still cancels. A transition before the buffer ends cancels. Starting another dictation with Fn cancels the old attempt; a later completion can start a new one.
- Cancellation never resumes when focus returns. Permission loss, Secure Input, missed input during an inspection, unresponsive AX, missing content/selection notifications, app exit or unreadable original state skips the attempt.

The service uses an active event tap on a dedicated thread. It passes the original switching event through after inserting a single Return pair. AX requests use a 5 ms messaging timeout and an overall 25 ms software check budget; overruns cancel sending. These are **not hard latency bounds**: macOS AX calls and the final config read can take longer, delaying that original event. The service never promises zero added latency.

Accessibility support varies. Both content and selection notifications, readable text and selection ranges are required; applications previously usable with focus-only inspection may now skip. Unsupported controls and uncertain transitions cancel rather than guessing. The automated runtime tests simulate macOS state and never post keys; owned AppKit experiments establish event ordering and background PID delivery only, not compatibility with every chat application.

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

For a Release installation, download and extract the new binary archive and run its `./install.sh`. It reuses the registered installation directory and preserves settings. For a source installation, update the source and rerun `./install.sh` in the existing directory. Reauthorize the replaced executable as described above. **Do not uninstall before upgrading**, because uninstall deletes the configuration.

Upgrading from **typeless-autoenter** keeps `config.json` unchanged, including enabled apps, pause state, delays, overrides and cancellation revisions. The installer stops and checks the old `local.typeless-autoenter` service before starting `local.typeless-autosend`, removes the old LaunchAgent and its owned command link, and installs `typeless-autosend`. It migrates the shell PATH marker and writes new logs to `autosend.log`; old `autoenter.log` files remain available. If the old service cannot be stopped, the upgrade aborts before starting a new service.

The installation directory may keep its old name. To rename a source installation, move the **whole existing directory** and rerun its `./install.sh`; do not install a separate checkout over a live installation. The existing instance lock and all configuration stay together. Update an existing clone's remote URL with `git remote set-url origin https://github.com/llj15/typeless-autosend.git`.

For scripts, `TYPELESS_AUTOSEND_CONFIG` overrides the config path. The legacy `TYPELESS_AUTOENTER_CONFIG` remains a fallback; the new variable wins if both are set.

```bash
~/typeless-autosend/uninstall.sh
```

Use the installed directory's `uninstall.sh` if it is elsewhere. Uninstall stops both current and legacy service names, removes their LaunchAgents and owned command links, and deletes this installation's `config.json`. If the service cannot be stopped, uninstall aborts and keeps the configuration. The program directory and shared PATH block remain. Remove the Accessibility entry manually if no longer needed.

## Build a Release archive

From a clean, committed checkout on macOS with Xcode Command Line Tools:

```bash
scripts/build-release.sh v1.1.0
```

This builds an optimized `arm64-apple-macosx15.0` binary, verifies its architecture and ad-hoc signature, checks CLI help, and writes the binary archive and `SHA256SUMS` to `dist/`. Only distribution files are included; personal configuration and runtime data are excluded. `BUILD_INFO` records the version and exact source commit. Publish the archive and its external checksum together.

## Tab completion

The installer enables completion for your login shell (zsh, bash or fish) in new
terminals. Complete commands, flags, output formats and configured Bundle IDs;
`apps add` also suggests installed apps. Fish users must have `~/.local/bin` on PATH.
For an existing installation, rerun the installer when upgrading, or enable it in
one session:

```bash
# zsh
source <(typeless-autosend completion zsh)
# bash (including macOS Bash 3.2)
source <(typeless-autosend completion bash)
# fish
typeless-autosend completion fish | source
```

`delay get --all` lists `globalDelaySeconds` and a sorted `apps` array covering
enabled apps and apps with overrides, including disabled ones. Each row has its
effective `delaySeconds`, nullable `overrideSeconds` and `enabled` state. With no
configured apps the array is empty. `--all` and `--app` are mutually exclusive.
Use `--format table` for a readable delay table. Reading delays never changes
configuration.
