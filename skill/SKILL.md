---
name: typeless-autosend
description: Operate the Typeless AutoSend CLI on macOS Apple Silicon to configure automatic sending or diagnose skipped sends.
---

# Typeless AutoSend

**Always run `typeless-autosend -h` before operating the CLI.** Then read the relevant subcommand's `-h`. Use the installed help as the command reference; do not guess commands or options.

## Workflow

1. Read help. If the command is missing, check `~/.local/bin` and PATH. Running the bare command starts another daemon and may produce an instance-lock message; it is not a help shortcut.
2. Inspect service state, enabled applications, and effective delay. Check `configPath`: configuration follows the actual executable or an environment override, not the working directory.
3. Find the application's Bundle ID through installed-app search. Do not pass a display name or executable path. Adding an app enables sending immediately.
4. Make the requested changes through the CLI and read them back. Avoid hand-editing JSON: CLI pause and removal operations record revisions that cancel pending sends.
5. For verification, have the user complete a new dictation in the enabled app, keep the input focused, and wait without pressing keys. Check the result and latest skip reason; do not inject Return into a live conversation as a test.

## Pitfalls and recovery

- App-specific delays override the global value. Actual waiting adds a fixed 150 ms paste buffer, even when the configured delay is zero.
- Real keys, including Fn/modifiers, and focus/caret changes cancel pending sends permanently. Returning focus does not resume them. Canceled attempts and transcriptions completed during pauses or listener outages are not replayed.
- Pause persists across restarts. Removing an app also removes its delay override.
- A running service may still be unable to send. Inspect its latest skip reason and `autosend.log` before changing settings; permissions, Secure Input, unreadable focus, and user activity need different responses.
- Accessibility provides this tool's event access; a separate Input Monitoring toggle is not required just because diagnostics use that name for listener health. After granting Accessibility, refresh stale permissions and rerun diagnostics:

  ```bash
  launchctl kickstart -k "gui/$(id -u)/local.typeless-autosend"
  ```

  Rebuilds can invalidate Accessibility entries: have the user remove a stale entry and add the current executable again. Secure Input can block listening despite valid permissions.
- Settings changes do not require reinstalling. Upgrade in place to retain configuration. Uninstall deletes `config.json`; do not use it to upgrade or troubleshoot.
- There is no CLI `--dry-run`. Discover output formats in help; `doctor` remains plain text, so check its exit status rather than expecting JSON.
