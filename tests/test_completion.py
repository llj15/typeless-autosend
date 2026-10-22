"""Exercise generated scripts in real shells and the read-only candidate protocol."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import test_cli
from test_cli import BIN


class CompletionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        test_cli.CLITests.setUpClass()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="typeless-complete-")
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "config.json"
        self.config.write_text(json.dumps({"apps": ["com.example.chat"],
            "appDelaySeconds": {"com.example.disabled": 2}}))
        self.env = dict(os.environ, TYPELESS_AUTOSEND_CONFIG=str(self.config))

    def run_cli(self, *args):
        return subprocess.run([str(BIN), *args], capture_output=True, text=True,
                              env=self.env, timeout=10)

    def candidates(self, *words):
        result = self.run_cli("completion", "candidates", "--", *words)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_candidates_follow_command_context_and_filter_prefixes(self):
        self.assertIn("delay", self.candidates(""))
        self.assertEqual(self.candidates("de"), ["delay"])
        self.assertEqual(self.candidates("delay", "g"), ["get"])
        self.assertEqual(self.candidates("completion", ""), ["bash", "fish", "zsh"])
        self.assertEqual(self.candidates("help", "delay", ""), ["get", "reset", "set"])
        self.assertIn("--all", self.candidates("schema", ""))
        self.assertEqual(self.candidates("delay", "get", "--a"), ["--all", "--app"])
        self.assertNotIn("--all", self.candidates("delay", "set", "1", "--"))
        self.assertNotIn("--all", self.candidates("delay", "get", "--app", "com.example.chat", "--"))
        self.assertNotIn("--app", self.candidates("delay", "get", "--all", "--"))
        self.assertNotIn("--all", self.candidates("delay", "get", "--all", "--"))
        self.assertEqual(self.candidates("delay", "get", "--format", "t"), ["table"])
        self.assertEqual(self.candidates("delay", "get", "--app", "com.example."),
                         ["com.example.chat", "com.example.disabled"])
        self.assertIn("--app", self.candidates("delay", "--format", "json", "set", "1", "--"))
        self.assertEqual(self.candidates("apps", "remove", "com.example."), ["com.example.chat"])
        self.assertIn("com.apple.finder", self.candidates("apps", "add", "com.apple.find"))

    def test_completion_does_not_mutate_config_or_interpret_shell_input(self):
        before = self.config.read_bytes()
        self.assertEqual(self.candidates("$(touch should-not-exist)"), [])
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse((Path.cwd() / "should-not-exist").exists())
        self.assertFalse(Path(str(self.config) + ".lock").exists())
        self.config.write_text("broken")
        self.assertIn("delay", self.candidates(""))
        self.assertEqual(self.candidates("delay", "get", "--app", ""), [])

    @unittest.skipUnless(os.environ.get("TYPELESS_TEST_FISH") or shutil.which("fish"), "fish is not installed")
    def test_fish_adapter_in_real_shell(self):
        fish = os.environ.get("TYPELESS_TEST_FISH") or shutil.which("fish")
        script = Path(self.temp.name) / "completion.fish"
        script.write_text(self.run_cli("completion", "fish").stdout)
        bindir = Path(self.temp.name) / "tools x[1]"
        bindir.mkdir()
        (bindir / "typeless-autosend").symlink_to(BIN)
        environment = dict(self.env, PATH=str(bindir) + ":" + os.environ.get("PATH", ""))
        for line, expected in [("typeless-autosend de", "delay"), ("typeless-autosend delay ", "get"),
                               ("typeless-autosend delay get --a", "--all"),
                               ("typeless-autosend delay get --format ", "json"),
                               ("typeless-autosend delay get --app com.example.c", "com.example.chat")]:
            with self.subTest(line=line):
                result = subprocess.run([fish, "-c", 'source "$argv[1]"; complete -C "$argv[2]"', str(script), line],
                                        env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, [entry.split("\t")[0] for entry in result.stdout.splitlines()])

    def test_generated_scripts_are_valid_and_unknown_shell_is_rejected(self):
        for shell, executable in (("zsh", "/bin/zsh"), ("bash", "/bin/bash"), ("fish", os.environ.get("TYPELESS_TEST_FISH") or shutil.which("fish"))):
            with self.subTest(shell=shell):
                result = self.run_cli("completion", shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                script = Path(self.temp.name) / ("completion." + shell)
                script.write_text(result.stdout)
                if executable:
                    syntax = subprocess.run([executable, "-n", str(script)], capture_output=True, text=True)
                    self.assertEqual(syntax.returncode, 0, syntax.stderr)
        for args in [("completion", "bash", "--json"), ("completion", "zsh", "--format", "table")]:
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 2, result.stderr)
        result = self.run_cli("completion", "invalid")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)["error"], "invalid_arguments")

    def test_bash_adapter_handles_empty_current_word_and_flags(self):
        script = Path(self.temp.name) / "completion.bash"
        script.write_text(self.run_cli("completion", "bash").stdout)
        # Exercise a path with spaces and glob characters, under Bash 3.2 POSIX mode.
        weird = Path(self.temp.name) / "tools x[1]"
        weird.mkdir()
        (weird / "typeless-autosend").symlink_to(BIN)
        binary = str(weird / "typeless-autosend")
        for words, expected in ((["delay", "get", ""], "--all"),
                                (["delay", "get", "--a"], "--app"),
                                (["delay", "get", "--app", "com.example.c"], "com.example.chat")):
            code = 'shopt -s failglob nullglob; source "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]}-1)); _typeless_autosend; printf "%s\\n" "${COMPREPLY[@]}"'
            result = subprocess.run(["/bin/bash", "--posix", "-c", code, "test", str(script), binary, *words],
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout.splitlines())

    def test_zsh_adapter_passes_words_to_completion_without_splitting(self):
        script = Path(self.temp.name) / "completion.zsh"
        script.write_text(self.run_cli("completion", "zsh").stdout)
        code = 'compdef() { :; }; compadd() { shift; printf "%s\\n" "$@"; }; source "$1"; shift; words=("$@"); CURRENT=${#words[@]}; _typeless_autosend'
        for words, expected in ((["delay", "get", ""], "--all"),
                                (["delay", "get", "--app", "com.example.c"], "com.example.chat")):
            result = subprocess.run(["/bin/zsh", "-f", "-c", code, "test", str(script), str(BIN), *words],
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout.splitlines())


if __name__ == "__main__":
    unittest.main()
