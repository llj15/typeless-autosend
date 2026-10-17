"""CLI behavior through a real subprocess and isolated configuration files."""
import json
import datetime as dt
from decimal import Decimal
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "tests" / ".cli-work"
BIN = Path(os.environ.get("TYPELESS_TEST_BINARY", str(WORK / "typeless-autoenter"))).resolve()


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("TYPELESS_TEST_BINARY"):
            if not BIN.is_file():
                raise RuntimeError(f"TYPELESS_TEST_BINARY does not exist: {BIN}")
            return
        WORK.mkdir(exist_ok=True)
        cli = ROOT / "CLI.swift"
        if "runCLI(arguments:" in (ROOT / "main.swift").read_text():
            sources = [str(path) for path in sorted(ROOT.glob("*.swift"))]
        elif cli.exists():
            # The harness invokes the same CLI entry point as the real executable.
            harness = WORK / "main.swift"
            harness.write_text('''import Foundation
import Darwin
let path = ProcessInfo.processInfo.environment["TYPELESS_AUTOENTER_CONFIG"]!
exit(runCLI(arguments: Array(CommandLine.arguments.dropFirst()), store: SettingsStore(path: path), serviceRunning: { false }) ?? 2)
''')
            sources = [str(ROOT / name) for name in ("Settings.swift", "Applications.swift", "CLI.swift")]
            sources.append(str(harness))
        else:
            sources = [str(ROOT / "main.swift")]
        subprocess.run(["swiftc", *sources, "-o", str(BIN), "-lsqlite3"], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="typeless-cli-")
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "config.json"

    def command(self, *args):
        env = dict(os.environ, TYPELESS_AUTOENTER_CONFIG=str(self.config))
        return subprocess.run([str(BIN), *args], env=env, capture_output=True, text=True, timeout=10)

    def result(self, *args):
        completed = self.command(*args)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def test_added_bundle_id_is_immediately_enabled_and_persisted(self):
        self.result("apps", "add", "COM.Example.Chat")
        apps = self.result("apps", "list")["apps"]
        self.assertEqual([(app["bundleID"], app["enabled"]) for app in apps], [("com.example.chat", True)])

    def test_legacy_apps_remain_enabled_after_removing_an_app(self):
        self.config.write_text(json.dumps({"apps": ["com.example.keep", "com.example.remove"], "futureSetting": {"keep": True}}))
        self.result("apps", "remove", "com.example.remove")
        self.assertEqual([app["bundleID"] for app in self.result("apps", "list")["apps"]], ["com.example.keep"])

    def test_cli_mutations_preserve_unknown_numeric_configuration_fields(self):
        original = '{"apps":[],"futureID":9007199254740993,"nested":{"counter":18446744073709551615,"ratio":1.2345678901234567890123456789012345678}}'
        self.config.write_text(original)
        self.result("apps", "add", "com.example.chat")
        expected = json.loads(original, parse_float=Decimal)
        saved = json.loads(self.config.read_text(), parse_float=Decimal)
        self.assertEqual({key: saved[key] for key in ("futureID", "nested")},
                         {key: expected[key] for key in ("futureID", "nested")})

    def test_cli_mutations_preserve_unknown_json_beyond_typed_numeric_ranges(self):
        raw = '{"number":1e300,"fraction":0.1234567890123456789012345678901234567890123456789,"array":["quote\\\"brace}\\\\",{"deep":12345678901234567890123456789012345678901234567890}]}'
        self.config.write_text('{"apps":[],"future":' + raw + '}')
        self.result("apps", "add", "com.example.chat")
        self.assertIn(raw, self.config.read_text())

    def test_cli_preserves_existing_json_encoding_support_and_numeric_text(self):
        raw = '{"counter":9007199254740993,"ratio":0.1234567890123456789012345678901234567890123456789}'
        original = '{"apps":[],"future":' + raw + '}'
        for encoding in ("utf-8-sig", "utf-16", "utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be"):
            with self.subTest(encoding=encoding):
                self.config.write_bytes(original.encode(encoding))
                self.result("apps", "add", "com.example.chat")
                self.assertIn(raw, self.config.read_text(encoding="utf-8"))
                self.assertEqual(self.result("apps", "list")["count"], 1)

    def test_global_delay_defaults_to_one_and_accepts_fractional_seconds(self):
        self.assertEqual(self.result("delay", "get")["delaySeconds"], 1)
        self.result("delay", "set", "0.25")
        self.assertEqual(self.result("delay", "get")["delaySeconds"], 0.25)

    def test_app_delay_override_and_reset_follow_global_delay(self):
        self.result("apps", "add", "com.example.chat")
        self.result("delay", "set", "0.75")
        self.result("delay", "set", "0", "--app", "COM.Example.Chat")
        self.assertEqual(self.result("delay", "get", "--app", "com.example.chat")["delaySeconds"], 0)
        self.result("delay", "reset", "--app", "com.example.chat")
        self.assertEqual(self.result("delay", "get", "--app", "com.example.chat")["delaySeconds"], 0.75)
        self.result("delay", "reset")
        self.assertEqual(self.result("delay", "get")["delaySeconds"], 1)

    def test_pause_and_resume_persist_across_cli_processes(self):
        self.result("service", "pause")
        self.assertTrue(self.result("service", "status")["paused"])
        self.result("service", "resume")
        self.assertFalse(self.result("service", "status")["paused"])

    def test_quick_pause_resume_and_remove_readd_preserve_cancellation_revisions(self):
        self.result("service", "pause")
        self.result("service", "resume")
        self.assertEqual(json.loads(self.config.read_text())["cancellationRevision"], 1)
        self.result("apps", "add", "com.example.chat")
        self.result("apps", "remove", "com.example.chat")
        self.result("apps", "add", "com.example.chat")
        self.result("apps", "add", "com.example.other")
        self.result("apps", "remove", "com.example.other")
        revisions = json.loads(self.config.read_text())["appCancellationRevisions"]
        self.assertEqual(revisions, {"com.example.chat": 1, "com.example.other": 1})

    def test_resume_records_cutoff_only_when_transitioning_from_paused(self):
        self.result("service", "resume")
        self.assertEqual(json.loads(self.config.read_text())["resumeAfter"], 0)
        self.result("service", "pause")
        before = time.time()
        self.result("service", "resume")
        cutoff = json.loads(self.config.read_text())["resumeAfter"]
        self.assertGreaterEqual(cutoff, before)
        self.assertLessEqual(cutoff, time.time())
        self.result("service", "resume")
        self.assertEqual(json.loads(self.config.read_text())["resumeAfter"], cutoff)

    def test_mutation_dry_runs_preview_without_persisting(self):
        preview = self.command("apps", "add", "com.example.preview", "--dry-run")
        self.assertEqual(preview.returncode, 10, preview.stderr)
        self.assertTrue(json.loads(preview.stdout)["dryRun"])
        self.assertEqual(self.result("apps", "list")["apps"], [])
        self.result("apps", "add", "com.example.chat")
        self.result("delay", "set", "0.5")
        for args in [("apps", "remove", "com.example.chat"), ("delay", "set", "2"),
                     ("delay", "reset"), ("delay", "set", "0", "--app", "com.example.chat"),
                     ("service", "pause")]:
            with self.subTest(args=args):
                preview = self.command(*args, "--dry-run")
                self.assertEqual(preview.returncode, 10, preview.stderr)
                self.assertTrue(json.loads(preview.stdout)["dryRun"])
        self.assertEqual(len(self.result("apps", "list")["apps"]), 1)
        self.assertEqual(self.result("delay", "get", "--app", "com.example.chat")["delaySeconds"], 0.5)
        self.assertFalse(self.result("service", "status")["paused"])

    def test_app_mutations_offer_explicit_idempotent_flags(self):
        self.result("apps", "add", "com.example.chat")
        conflict = self.command("apps", "add", "com.example.chat")
        self.assertEqual(conflict.returncode, 5, conflict.stderr)
        self.assertEqual(json.loads(conflict.stderr)["error"], "already_exists")
        self.assertFalse(self.result("apps", "add", "com.example.chat", "--if-not-exists")["changed"])
        self.result("apps", "remove", "com.example.chat")
        missing = self.command("apps", "remove", "com.example.chat")
        self.assertEqual(missing.returncode, 3, missing.stderr)
        self.assertFalse(self.result("apps", "remove", "com.example.chat", "--if-exists")["changed"])

    def test_search_discovers_installed_apps_by_name_and_bundle_id(self):
        for query in ("Finder", "COM.APPLE.FINDER"):
            with self.subTest(query=query):
                apps = self.result("apps", "search", query)["apps"]
                finder = next(app for app in apps if app["bundleID"] == "com.apple.finder")
                self.assertTrue(finder["installed"])
                self.assertIsInstance(finder["running"], bool)
                self.assertIn("Finder", finder["name"])

    def test_search_also_finds_installed_apps_that_are_not_running(self):
        installed = self.result("apps", "search")["apps"]
        candidate = next(app for app in installed if app["installed"] and not app["running"])
        found = self.result("apps", "search", candidate["bundleID"])["apps"]
        self.assertIn(candidate["bundleID"], [app["bundleID"] for app in found])

    def test_invalid_inputs_return_actionable_json_errors_without_mutation(self):
        invalid = [("apps", "add", "Slack"), ("apps", "add", "com.example/chat"),
                   ("apps", "add", "com.example.chat", "--disabled"),
                   ("apps", "add", "com.example.chat", "--if-exists"),
                   ("delay", "set", "-1"), ("delay", "set", "nan"), ("delay", "set", "inf"),
                   ("delay", "get", "--dry-run"), ("service", "pause", "--app", "com.example.chat"),
                   ("delay", "get", "--app"), ("--app", "com.example.chat")]
        for args in invalid:
            with self.subTest(args=args):
                completed = self.command(*args)
                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertEqual(completed.stdout, "")
                error = json.loads(completed.stderr)
                self.assertEqual(error["error"], "invalid_arguments")
                self.assertTrue(error["suggestion"])
                self.assertFalse(error["retryable"])
                self.assertEqual(error["input"], list(args))
        self.assertEqual(self.result("apps", "list")["apps"], [])

    def test_parallel_app_additions_do_not_overwrite_each_other(self):
        self.config.write_text(json.dumps({"apps": [], "extensionPayload": "x" * 500000}))
        env = dict(os.environ, TYPELESS_AUTOENTER_CONFIG=str(self.config))
        processes = [subprocess.Popen([str(BIN), "apps", "add", f"com.example.parallel{i}"], env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for i in range(16)]
        for process in processes:
            _, error = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, error)
        self.assertEqual(self.result("apps", "list")["count"], 16)

    def test_output_formats_are_explicit_and_dry_run_stays_json(self):
        self.result("apps", "add", "com.example.chat", "--json")
        self.assertEqual(self.result("apps", "list", "--format", "json")["count"], 1)
        table = self.command("apps", "list", "--format", "table")
        self.assertEqual(table.returncode, 0, table.stderr)
        self.assertIn("BUNDLE ID", table.stdout)
        self.assertIn("com.example.chat", table.stdout)
        preview = self.command("delay", "set", "2", "--format", "table", "--dry-run")
        self.assertEqual(preview.returncode, 10, preview.stderr)
        self.assertEqual(json.loads(preview.stdout)["delaySeconds"], 2)
        self.assertEqual(self.command("apps", "list", "--format", "csv").returncode, 2)

    def test_config_delay_overrides_are_normalized_and_invalid_delays_fail_closed(self):
        self.config.write_text(json.dumps({"apps": ["com.example.chat"], "appDelaySeconds": {"COM.Example.Chat": 0.2}}))
        self.assertEqual(self.result("delay", "get", "--app", "com.example.chat")["delaySeconds"], 0.2)
        for bad in ({"apps": [], "delaySeconds": -1}, {"apps": [], "appDelaySeconds": {"com.example.chat": -1}}, {}):
            with self.subTest(config=bad):
                self.config.write_text(json.dumps(bad))
                completed = self.command("service", "status")
                self.assertEqual(completed.returncode, 1, completed.stdout)
                self.assertEqual(json.loads(completed.stderr)["error"], "configuration_error")

    def test_delays_beyond_the_system_scheduler_range_are_rejected(self):
        for args in [("delay", "set", "1e100"), ("delay", "set", "1e100", "--app", "com.example.chat")]:
            with self.subTest(args=args):
                completed = self.command(*args)
                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn("range", json.loads(completed.stderr)["message"])
        for config in ({"apps": [], "delaySeconds": 1e100}, {"apps": [], "appDelaySeconds": {"com.example.chat": 1e100}}):
            with self.subTest(config=config):
                self.config.write_text(json.dumps(config))
                completed = self.command("delay", "get")
                self.assertEqual(completed.returncode, 1, completed.stdout)

    def test_help_and_schema_describe_the_supported_command_contract(self):
        for args in [("--help",), ("apps", "--help"), ("delay", "set", "--help"), ("help", "apps", "add")]:
            with self.subTest(args=args):
                completed = self.command(*args)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn("--json", completed.stdout)
                self.assertIn("10", completed.stdout)
                self.assertLessEqual(len(completed.stdout.splitlines()), 50)
        schema = self.result("schema", "--all")
        self.assertEqual(schema["schemaVersion"], 1)
        self.assertIn("service status", [command["name"] for command in schema["commands"]])
        add = self.result("schema", "apps", "add")
        self.assertEqual(add["name"], "apps add")
        self.assertTrue(add["arguments"][0]["required"])
        self.assertIn("--if-not-exists", [flag["name"] for flag in add["flags"]])

    def test_service_status_reads_current_runtime_skip_reason_and_ignores_stale_status(self):
        status = Path(self.temp.name) / "runtime-status.json"
        data = {"pid": os.getpid(), "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                "lastSkipReason": "manual_input", "pending": False, "inputMonitoringAvailable": True}
        status.write_text(json.dumps(data))
        current = self.result("service", "status")
        self.assertEqual(current["lastSkipReason"], "manual_input")
        self.assertTrue(current["running"])
        self.assertTrue(current["inputMonitoringAvailable"])
        data["updatedAt"] = "2000-01-01T00:00:00Z"
        status.write_text(json.dumps(data))
        self.assertIsNone(self.result("service", "status")["lastSkipReason"])


if __name__ == "__main__":
    unittest.main()
