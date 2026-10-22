"""Release installer subprocesses with an isolated HOME and stub OS services."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LABEL = "local.typeless-autosend"


class ReleaseInstallTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / "tests" / ".release-work"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.bundle = self.home / "Downloads" / "AutoSend Release"
        support = self.bundle / "support"
        support.mkdir(parents=True)
        for name in ("uninstall.sh", "config.example.json"):
            shutil.copy2(ROOT / name, support)
        shutil.copy2(ROOT / "install.sh", support / "install-service.sh")
        shutil.copytree(ROOT / "skill", support / "skill")
        (support / "BUILD_INFO").write_text("version=v1.0.0\n")
        wrapper = ROOT / "scripts" / "install-release.sh"
        if wrapper.exists():
            shutil.copy2(wrapper, self.bundle / "install.sh")
        binary = self.bundle / "bin" / "typeless-autosend"
        binary.parent.mkdir()
        binary.write_text('#!/bin/bash\necho "release sandbox doctor"\n')
        binary.chmod(0o755)
        with (self.bundle / "SHA256SUMS").open("w") as manifest:
            subprocess.run(["/usr/bin/shasum", "-a", "256", "bin/typeless-autosend"],
                           cwd=self.bundle, stdout=manifest, check=True)
        self.target = self.home / "typeless-autosend"
        self.agents = self.home / "Library" / "LaunchAgents"
        self.agents.mkdir(parents=True)
        self.stubs = self.home / "stubs"
        self.stubs.mkdir()
        commands = {
            "swiftc": '#!/bin/bash\necho "compiler must not run" >&2\nexit 99\n',
            "open": '#!/bin/bash\nprintf "%s\\n" "$@" >> "$HOME/open.log"\n',
            "launchctl": '''#!/usr/bin/python3
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
''',
        }
        for name, source in commands.items():
            path = self.stubs / name
            path.write_text(source)
            path.chmod(0o755)

    def run_install(self, *args, **extra):
        return subprocess.run(["/bin/bash", str(self.bundle / "install.sh"), *args],
            cwd=self.home, env=dict(os.environ, HOME=str(self.home), SHELL="/bin/zsh",
                                   PATH=f"{self.stubs}:/usr/bin:/bin", **extra),
            capture_output=True, text=True, timeout=20)

    def existing_install(self, label=LABEL, command="typeless-autosend"):
        self.target = self.home / "My Tools" / "Existing Install"
        self.target.mkdir(parents=True)
        binary = self.target / command
        binary.write_text("old binary\n")
        binary.chmod(0o755)
        (self.agents / f"{label}.plist").write_bytes(plistlib.dumps({
            "Label": label, "ProgramArguments": [str(binary)]}))
        (self.home / "services.json").write_text(json.dumps({label: str(binary)}))
        commands = self.home / ".local/bin"
        commands.mkdir(parents=True)
        (commands / command).symlink_to(binary)
        self.original_config = b'{"apps":["com.openai.codex"],"paused":true,"delaySeconds":2,"future":9007199254740993}\n'
        (self.target / "config.json").write_bytes(self.original_config)

    def test_upgrade_reuses_existing_directory_and_preserves_config_bytes(self):
        self.existing_install()
        result = self.run_install("--app", "com.example.ignored")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / "config.json").read_bytes(), self.original_config)
        self.assertIn("release sandbox doctor", (self.target / "typeless-autosend").read_text())
        self.assertEqual(json.loads((self.home / "services.json").read_text()),
                         {LABEL: str(self.target / "typeless-autosend")})
        self.assertFalse((self.home / "typeless-autosend").exists())

    def test_failed_stop_preserves_old_binary_config_and_registration(self):
        self.existing_install()
        result = self.run_install(SBX_STOP_FAIL=LABEL)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not be stopped", result.stderr)
        self.assertEqual((self.target / "typeless-autosend").read_text(), "old binary\n")
        self.assertEqual((self.target / "config.json").read_bytes(), self.original_config)
        self.assertEqual(json.loads((self.home / "services.json").read_text()),
                         {LABEL: str(self.target / "typeless-autosend")})
        self.assertTrue((self.agents / f"{LABEL}.plist").exists())

    def test_legacy_upgrade_keeps_config_and_removes_old_command(self):
        old = "local.typeless-autoenter"
        self.existing_install(label=old, command="typeless-autoenter")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / "config.json").read_bytes(), self.original_config)
        self.assertFalse((self.target / "typeless-autoenter").exists())
        self.assertFalse((self.home / ".local/bin/typeless-autoenter").is_symlink())
        self.assertFalse((self.agents / f"{old}.plist").exists())
        self.assertEqual(json.loads((self.home / "services.json").read_text()),
                         {LABEL: str(self.target / "typeless-autosend")})

    def test_corrupt_binary_does_not_touch_existing_installation(self):
        self.existing_install()
        (self.bundle / "bin/typeless-autosend").write_text("damaged\n")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum verification failed", result.stderr)
        self.assertEqual((self.target / "typeless-autosend").read_text(), "old binary\n")
        self.assertEqual((self.target / "config.json").read_bytes(), self.original_config)
        self.assertFalse((self.home / "launchctl.log").exists())

    def test_conflicting_registrations_abort_without_stopping_either_service(self):
        self.existing_install()
        other = self.home / "old-install"
        other.mkdir()
        old = "local.typeless-autoenter"
        (self.agents / f"{old}.plist").write_bytes(plistlib.dumps({
            "Label": old, "ProgramArguments": [str(other / "typeless-autoenter")]}))
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Two different installations", result.stderr)
        self.assertEqual((self.target / "typeless-autosend").read_text(), "old binary\n")
        self.assertFalse((self.home / "launchctl.log").exists())

    def test_existing_unrelated_command_is_not_overwritten(self):
        command = self.home / ".local/bin/typeless-autosend"
        command.parent.mkdir(parents=True)
        command.write_text("unrelated tool\n")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Command already exists", result.stderr)
        self.assertEqual(command.read_text(), "unrelated tool\n")
        self.assertFalse((self.home / "launchctl.log").exists())

    def test_installed_uninstaller_works_after_bundle_removal_and_deletes_config(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        shutil.rmtree(self.bundle)
        result = subprocess.run(["/bin/bash", str(self.target / "uninstall.sh")],
            env=dict(os.environ, HOME=str(self.home), PATH=f"{self.stubs}:/usr/bin:/bin"),
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.home / "services.json").read_text()), {})
        self.assertFalse((self.target / "config.json").exists())
        self.assertFalse((self.home / ".local/bin/typeless-autosend").is_symlink())
        self.assertFalse((self.agents / f"{LABEL}.plist").exists())

    def test_downloaded_release_installs_without_compiler_and_survives_bundle_removal(self):
        result = self.run_install("--app", "com.openai.codex")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.target / "config.json").read_text()),
                         {"apps": ["com.openai.codex"]})
        plist = plistlib.loads((self.agents / f"{LABEL}.plist").read_bytes())
        self.assertEqual(plist["ProgramArguments"], [str(self.target / "typeless-autosend")])
        self.assertEqual((self.home / ".local/bin/typeless-autosend").resolve(),
                         self.target / "typeless-autosend")
        self.assertEqual((self.target / "BUILD_INFO").read_text(), "version=v1.0.0\n")
        self.assertTrue((self.target / "uninstall.sh").exists())
        self.assertTrue((self.target / "skill/SKILL.md").exists())
        self.assertFalse((self.home / "open.log").exists())
        self.assertNotIn("Permission setup:", result.stdout)
        self.assertNotIn("Opening this page does not grant permission", result.stdout)
        shutil.rmtree(self.bundle)
        smoke = subprocess.run([str(self.home / ".local/bin/typeless-autosend"), "-h"],
                               capture_output=True, text=True, check=True)
        self.assertIn("release sandbox doctor", smoke.stdout)


if __name__ == "__main__":
    unittest.main()
