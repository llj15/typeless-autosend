"""Install/upgrade/uninstall through scripts with sandboxed macOS boundaries."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
NEW = "local.typeless-autosend"
OLD = "local.typeless-autoenter"


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / "tests" / ".upgrade-work"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.directory = self.home / "My Tools" / "typeless-autosend"
        self.directory.mkdir(parents=True)
        for source in [*ROOT.glob("*.swift"), ROOT / "install.sh", ROOT / "uninstall.sh", ROOT / "config.example.json"]:
            shutil.copy2(source, self.directory)
        self.stubs = self.home / "stubs"
        self.stubs.mkdir()
        compiler = self.stubs / "swiftc"
        compiler.write_text('''#!/bin/bash
if [ "$1" = --version ]; then exit 0; fi
out=""; while [ $# -gt 0 ]; do if [ "$1" = -o ]; then out="$2"; fi; shift; done
printf '#!/bin/bash\\necho "sandbox doctor"\\n' > "$out"
chmod +x "$out"
''')
        launchctl = self.stubs / "launchctl"
        launchctl.write_text('''#!/usr/bin/python3
import json, os, pathlib, plistlib, sys
home = pathlib.Path(os.environ["HOME"])
path = home / "services.json"
services = json.loads(path.read_text()) if path.exists() else {}
args = sys.argv[1:]
with (home / "launchctl.log").open("a") as log: log.write(json.dumps(args) + "\\n")
label = args[1].split("/")[-1]
if args[0] == "bootout":
    if label != os.environ.get("SBX_STOP_FAIL"): services.pop(label, None)
elif args[0] == "print":
    sys.exit(0 if label in services else 1)
elif args[0] == "bootstrap":
    plist = plistlib.loads(pathlib.Path(args[2]).read_bytes())
    services[plist["Label"]] = plist["ProgramArguments"][0]
    pathlib.Path(plist["StandardOutPath"]).write_text("started, accessibility trusted=false\\n")
path.write_text(json.dumps(services))
''')
        compiler.chmod(0o755)
        launchctl.chmod(0o755)
        opener = self.stubs / "open"
        opener.write_text('#!/bin/bash\nprintf \'%s\\n\' "$@" >> "$HOME/open.log"\nexit 0\n')
        opener.chmod(0o755)
        self.agents = self.home / "Library" / "LaunchAgents"
        self.agents.mkdir(parents=True)
        self.bin = self.home / ".local" / "bin"
        self.bin.mkdir(parents=True)

    def run_script(self, script="install.sh", **extra):
        environment = dict(os.environ, HOME=str(self.home), SHELL="/bin/zsh",
                           PATH=f"{self.stubs}:/usr/bin:/bin")
        environment.update(extra)
        return subprocess.run(["/bin/bash", script], cwd=self.directory, env=environment,
                              capture_output=True, text=True, timeout=20)

    def test_bash_completion_profile_is_preserved_and_idempotent(self):
        profile = self.home / ".bash_profile"
        profile.write_text("# user settings\n")
        for _ in range(2):
            result = self.run_script(SHELL="/bin/bash")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        text = profile.read_text()
        self.assertTrue(text.startswith("# user settings\n"))
        self.assertEqual(text.count("# >>> typeless-autosend completion >>>"), 1)
        self.assertIn('typeless-autosend completion bash', text)
        syntax = subprocess.run(["/bin/bash", "--posix", "-n", str(profile)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_zsh_completion_honors_zdotdir_even_when_path_already_exists(self):
        dotdir = self.home / "shell config x[1]"
        dotdir.mkdir()
        profile = dotdir / ".zshrc"
        profile.write_text("# user settings\n")
        result = self.run_script(ZDOTDIR=str(dotdir), PATH=f"{self.bin}:{self.stubs}:/usr/bin:/bin")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        text = profile.read_text()
        self.assertIn("typeless-autosend completion zsh", text)
        self.assertNotIn("# >>> typeless-autosend PATH >>>", text)
        syntax = subprocess.run(["/bin/zsh", "-n", str(profile)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_fish_completion_honors_xdg_and_preserves_existing_file(self):
        config = self.home / "fish config x[1]"
        completion = config / "fish/completions/typeless-autosend.fish"
        for _ in range(2):
            result = self.run_script(SHELL="/opt/homebrew/bin/fish", XDG_CONFIG_HOME=str(config))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(completion.read_text().count("typeless-autosend completion fish | source"), 1)
        completion.write_text("# custom completion\n")
        result = self.run_script(SHELL="/opt/homebrew/bin/fish", XDG_CONFIG_HOME=str(config))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(completion.read_text(), "# custom completion\n")

    def legacy_install(self):
        binary = self.directory / "typeless-autoenter"
        binary.write_text("#!/bin/bash\nexit 0\n")
        binary.chmod(0o755)
        (self.bin / "typeless-autoenter").symlink_to(binary)
        (self.agents / f"{OLD}.plist").write_bytes(plistlib.dumps({
            "Label": OLD, "ProgramArguments": [str(binary)]}))
        (self.home / "services.json").write_text(json.dumps({OLD: str(binary)}))
        (self.home / ".zshrc").write_text("# >>> typeless-autoenter PATH >>>\nexport PATH=\"$HOME/.local/bin:$PATH\"\n# <<< typeless-autoenter PATH <<<\n")
        self.config = self.directory / "config.json"
        self.config.write_bytes(b'{"apps":["com.mitchellh.ghostty"],"delaySeconds":1,"paused":true,"appDelaySeconds":{"com.mitchellh.ghostty":0.5},"resumeAfter":123,"cancellationRevision":7,"appCancellationRevisions":{"com.mitchellh.ghostty":3},"future":9007199254740993}\n')
        self.original = self.config.read_bytes()

    def services(self):
        return json.loads((self.home / "services.json").read_text())

    def calls(self):
        return [json.loads(line) for line in (self.home / "launchctl.log").read_text().splitlines()]

    def test_legacy_upgrade_preserves_all_config_and_replaces_service_and_command(self):
        self.legacy_install()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.services(), {NEW: str(self.directory / "typeless-autosend")})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse((self.agents / f"{OLD}.plist").exists())
        self.assertFalse((self.bin / "typeless-autoenter").is_symlink())
        self.assertFalse((self.directory / "typeless-autoenter").exists())
        self.assertEqual((self.bin / "typeless-autosend").resolve(), self.directory / "typeless-autosend")
        commands = [call[0] for call in self.calls()]
        stop = next(i for i, call in enumerate(self.calls()) if call[:2] == ["bootout", f"gui/{os.getuid()}/{OLD}"])
        self.assertLess(stop, commands.index("bootstrap"))
        profile = (self.home / ".zshrc").read_text()
        self.assertNotIn("typeless-autoenter PATH", profile)
        self.assertEqual(profile.count("# >>> typeless-autosend PATH >>>"), 1)
        again = self.run_script()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.services(), {NEW: str(self.directory / "typeless-autosend")})

    def test_upgrade_from_another_checkout_keeps_existing_install_and_settings(self):
        self.legacy_install()
        previous = self.directory
        self.directory = self.home / "another-checkout"
        shutil.copytree(previous, self.directory, ignore=shutil.ignore_patterns("config.json", "typeless-autoenter"))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("existing installation", result.stderr)
        self.assertEqual(self.services(), {OLD: str(previous / "typeless-autoenter")})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse((self.directory / "config.json").exists())
        self.assertFalse((self.home / "launchctl.log").exists())

    def test_uninstall_stops_both_names_and_removes_config_but_keeps_unrelated_links(self):
        self.legacy_install()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        # Model a leftover registration from before the rename.
        services = self.services()
        services[OLD] = str(self.directory / "typeless-autoenter")
        (self.home / "services.json").write_text(json.dumps(services))
        (self.agents / f"{OLD}.plist").write_bytes(plistlib.dumps({"Label": OLD}))
        unrelated = self.home / "another-tool"
        unrelated.write_text("keep")
        (self.bin / "typeless-autoenter").symlink_to(unrelated)
        result = self.run_script("uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.services(), {})
        self.assertFalse((self.agents / f"{NEW}.plist").exists())
        self.assertFalse((self.agents / f"{OLD}.plist").exists())
        self.assertFalse((self.bin / "typeless-autosend").is_symlink())
        self.assertEqual((self.bin / "typeless-autoenter").resolve(), unrelated)
        self.assertFalse(self.config.exists())

    def test_missing_registered_binary_does_not_reset_config_in_other_checkout(self):
        self.legacy_install()
        previous = self.directory
        (previous / "typeless-autoenter").unlink()
        self.directory = self.home / "another-checkout"
        shutil.copytree(previous, self.directory, ignore=shutil.ignore_patterns("config.json"))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("existing installation", result.stderr)
        self.assertEqual(self.services(), {OLD: str(previous / "typeless-autoenter")})
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse((self.directory / "config.json").exists())

    def test_moving_whole_legacy_install_repairs_dangling_link_without_losing_state(self):
        self.legacy_install()
        previous = self.directory
        self.directory = self.home / "renamed-install"
        previous.rename(self.directory)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.services(), {NEW: str(self.directory / "typeless-autosend")})
        self.assertEqual((self.directory / "config.json").read_bytes(), self.original)
        self.assertFalse((self.bin / "typeless-autoenter").is_symlink())
        self.assertFalse((self.directory / "typeless-autoenter").exists())
        self.assertEqual((self.bin / "typeless-autosend").resolve(), self.directory / "typeless-autosend")

    def test_upgrade_aborts_when_legacy_service_cannot_be_stopped(self):
        self.legacy_install()
        result = self.run_script(SBX_STOP_FAIL=OLD)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("could not be stopped", result.stderr)
        self.assertEqual(self.services(), {OLD: str(self.directory / "typeless-autoenter")})
        self.assertNotIn("bootstrap", [call[0] for call in self.calls()])
        self.assertTrue((self.agents / f"{OLD}.plist").exists())
        self.assertTrue((self.bin / "typeless-autoenter").is_symlink())
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_new_command_conflict_does_not_stop_legacy_service(self):
        self.legacy_install()
        command = self.bin / "typeless-autosend"
        command.write_text("another tool")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Command already exists", result.stderr)
        self.assertEqual(command.read_text(), "another tool")
        self.assertEqual(self.services(), {OLD: str(self.directory / "typeless-autoenter")})
        self.assertFalse((self.home / "launchctl.log").exists())
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_uninstall_failure_keeps_registration_and_owned_command(self):
        self.legacy_install()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_script("uninstall.sh", SBX_STOP_FAIL=NEW)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Stop it manually", result.stderr)
        self.assertEqual(self.services(), {NEW: str(self.directory / "typeless-autosend")})
        self.assertTrue((self.agents / f"{NEW}.plist").exists())
        self.assertTrue((self.bin / "typeless-autosend").is_symlink())
        self.assertEqual(self.config.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
