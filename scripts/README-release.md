# Typeless AutoSend @VERSION@

Precompiled for **Apple Silicon (arm64), macOS 15 or later**. Install Typeless,
sign in, and enable its transcription history first. Swift, Xcode, Node.js and npm
are not required to install this package.

## Install

Extract `typeless-autosend-@VERSION@-macos-arm64.tar.gz`, then run:

```bash
cd typeless-autosend-@VERSION@-macos-arm64
./install.sh
```

The installer verifies the bundled checksums and installs in `~/typeless-autosend`.
If a previous installation is registered, it upgrades that directory instead and
preserves `config.json` unchanged. It links `~/.local/bin/typeless-autosend`, sets
up your shell PATH if needed, and registers the login service. You can delete the
downloaded archive and extracted directory after installation.

The installer runs `doctor` automatically. If it reports missing Accessibility
or input-listening permission, the installer opens Accessibility settings and
prints authorization steps. When checks pass, no permission setup is needed.
For a permission failure, enable the installed executable shown in its output,
then run the printed `launchctl kickstart` command. An upgrade may
require removing a stale Accessibility entry and adding the new executable.
Separate Input Monitoring permission is not required. The binary is ad-hoc signed;
this release is not Developer ID signed or notarized. If macOS blocks a downloaded
file, use its system approval flow before continuing.

Open a new terminal, then start with help:

```bash
typeless-autosend -h
typeless-autosend apps search Codex
typeless-autosend apps add com.openai.codex
typeless-autosend delay get --all
typeless-autosend delay set 1
typeless-autosend service status
```

Fresh installs enable no applications. Running the bare command starts a daemon;
the installer already started the service, so use subcommands to configure it.
The AI usage skill is installed at `<installation-directory>/skill/SKILL.md`.
Logs, configuration, and `BUILD_INFO` are in the installation directory.

## Upgrade

Download and extract the next Release archive and run its `./install.sh` again.
Do not uninstall first: uninstall removes your configuration.

## Uninstall

For the default installation:

```bash
~/typeless-autosend/uninstall.sh
```

If upgrading an installation in another directory, use its `uninstall.sh` instead.
The script stops the service, removes owned command links and LaunchAgents, and
deletes `config.json`. The program directory and guarded shell setup remain; completion loaders are inert when the command is absent.
Remove its Accessibility entry manually if no longer needed.

Tab completion for zsh, bash and fish is enabled by the installer for new terminals.
For the current terminal, run `source <(typeless-autosend completion zsh)` (zsh),
`source <(typeless-autosend completion bash)` (bash), or
`typeless-autosend completion fish | source` (fish). Fish needs `~/.local/bin` on PATH.
Use `delay get --all` to inspect global and app delays, including disabled overrides.
