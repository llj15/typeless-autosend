# Typeless AutoSend

A macOS command-line utility and login service for Apple Silicon (ARM). After Typeless finishes a transcription in an enabled application, it sends on application deactivation, an intercepted outside click, or countdown expiry. Editing the pasted text, moving its caret, or an already completed change of input focus cancels that send.

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

- The service captures the original input immediately before Typeless pastes. After the 150 ms paste buffer, it identifies the lines containing the pasted text using the insertion point or the change between the before/after snapshots. If it cannot locate those lines, it compares the whole input instead.
- Changes to the tracked lines cancel permanently. Refreshes elsewhere in a screen-sized input do not cancel a located region. Caret or selection changes also cancel when the application reports them. These checks run while the original application is frontmost.
- Keyboard events alone do not cancel or send. Clicking inside the original input keeps the countdown unless its content or selection changes. Its Accessibility ancestors and descendants count as the same input.
- After the paste buffer, a confirmed outside click in the original application posts Return before the event-tap callback releases the click. The destination can be another input, a button or blank space. An uncertain Accessibility relationship does not trigger an early send.
- Switching to another application or desktop sends to the original PID without activating it, after a final comparison of the original input. Leaving during the paste buffer queues the send until the buffer finishes; it proceeds only if the original input has not already lost focus to another input in the same application.
- If a notification confirms that another window or input in the same application has already gained focus, the attempt cancels. PID delivery cannot address an old input object. This is a deliberate limitation relative to the design; see [implementation notes](docs/implementation-notes-leave-to-send.md).
- A departure also requires a readable identity for the original application's focused window and input. Unavailable identity cancels that attempt. Unreadable text alone is not treated as editing; expiry does not reread text or selection.
- A newer local database record cancels the pending attempt, including a new dictation whose status is still empty. This does not depend on a dictation shortcut.
- If you stay in the original input, expiry sends without rereading its text or selection. The attempt must still be active and authorized, with a live original process, available permissions and Secure Input off.
- Cancellation never resumes when focus returns. Pausing, disabling the app, permission loss, Secure Input, a listener interruption or the original app exiting cancels the attempt.

The service uses an active event tap on a dedicated thread and posts a single Return pair to the original PID. AX requests use a 5 ms messaging timeout and an overall 25 ms software check budget. These are **not hard latency bounds**: macOS AX calls and the final config read can take longer, delaying an intercepted click.

Accessibility support varies. Readable input text is needed to establish a baseline; controls without caret information use content alignment. Automated unit tests cover the region algorithm, simulated macOS events and dry-run sends without posting keys. They do not establish compatibility with every real application.

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
