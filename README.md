# typeless-autoenter

After Typeless finishes a transcription and pastes the text into the input box, press Return once to send it. Works only in the apps you choose. macOS only.

## How it works

Typeless has no official hook. Every time a transcription finishes, it writes a record to a local SQLite database (`~/Library/Application Support/Typeless/typeless.db`). This program checks every 100 ms whether the database files have changed, and reads the database only when they have. When it sees a new "completed" record and the frontmost app is on the whitelist, it waits 150 ms and sends one Return.

## Prerequisites

- macOS, with Typeless installed and signed in
- Xcode Command Line Tools: `xcode-select --install` (the install script builds on your machine)
- Keep this directory somewhere unprotected, for example `~/Developer/typeless-autoenter`. **Do not put it in Desktop, Documents, Downloads or iCloud**: the background service cannot read files there (`install.sh` refuses to install).
- Keep Typeless history turned on (it is kept forever by default; `doctor` checks this)

## Install

```bash
./install.sh --app com.mitchellh.ghostty    # --app can be repeated; writes the whitelist on first install
```

The script builds the binary, generates and loads a LaunchAgent (`local.typeless-autoenter`, starts at login), creates `config.json`, and runs a self-check. The program, config and log all live in this directory, so **do not move it after installing**; if you do, re-run `./install.sh`.

### Grant Accessibility permission (required)

Sending Return needs Accessibility permission. The first start after installing shows a prompt once; turn on `typeless-autoenter` in System Settings → Privacy & Security → Accessibility.

If no prompt appears, or an old entry is already listed: remove it with `−`, then add the `typeless-autoenter` in this directory with `+`.

## Configuration: `config.json`

```json
{
  "apps": [
    "com.mitchellh.ghostty",
    "com.tinyspeck.slackmacgap"
  ]
}
```

- `config.json` is the only source of the whitelist. It is re-read every time a transcription finishes, so edits take effect immediately with no restart.
- To find a Bundle ID: open the target app, then run `./typeless-autoenter list-apps`. Menu-bar and launcher apps (Raycast, Alfred, ...) are only listed with `--all`.
- Matching is case-insensitive and ignores leading and trailing whitespace.
- A missing or invalid file, or an empty `apps`, means Return is never sent in any app; the reason is written to `autoenter.log` (`config missing` / `config invalid` / `config has no apps`).
- Code editors are not recommended: with the cursor in the code area, Return just inserts a newline.

## Self-check

```bash
./typeless-autoenter doctor
```

Checks Typeless, the database and its schema, the history retention setting, the whitelist, and the background service's permission and running state.

## Upgrade

Update the source, then re-run `./install.sh`. The binary changes, so the Accessibility permission goes stale: remove the old entry and add it again, as described above.

## Known limitations

- Return is sent a fixed 150 ms after the record is seen, and there is no way to confirm that Typeless has finished pasting. If the paste fails or is unusually slow, an empty Return may be sent.
- It depends on Typeless's local database schema. If a Typeless upgrade changes the schema, the program stops triggering and writes `db read failing: ...` to the log.
- The Accessibility permission has to be redone after every rebuild.
- Only one instance runs at a time (`.lock` in this directory). A second instance waits up to 5 seconds for the lock, then exits. To try it by hand, first stop the background service with `./uninstall.sh`.

## Tests

```bash
tests/run.sh
```

Builds a separate binary and runs every `tests/test_*.py` (needs the Xcode Command Line Tools and `python3`). The tests use dry-run mode, throw-away databases and a sandboxed `HOME` with stub `swiftc` and `launchctl`, so they never touch an installed service. They take a few minutes; logs are kept in `tests/.work` only when something fails.

## Uninstall

```bash
./uninstall.sh
```

Stops the service and removes the LaunchAgent. The directory is not deleted, and the entry in the Accessibility list has to be removed by hand.
