"""Permission requests through daemon startup, with macOS APIs stubbed at link time.

The isolated executable cannot open real permission prompts, create event taps or
post keystrokes. Its database and configuration are temporary.
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class PermissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="autosend-permission-build-")
        cls.addClassCleanup(cls.build.cleanup)
        work = Path(cls.build.name)
        stub = work / "permissions.c"
        stub.write_text(r'''
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>

static void record(const char *request) {
    FILE *file = fopen(getenv("PERMISSION_TEST_REQUESTS"), "a");
    if (!file) abort();
    fprintf(file, "%s\n", request);
    fclose(file);
}
Boolean AXIsProcessTrustedWithOptions(CFDictionaryRef options) {
    if (options && CFDictionaryGetValue(options, kAXTrustedCheckOptionPrompt) == kCFBooleanTrue)
        record("accessibility");
    return getenv("PERMISSION_TEST_AX_GRANTED") != NULL;
}
bool CGPreflightListenEventAccess(void) {
    return getenv("PERMISSION_TEST_INPUT_GRANTED") != NULL;
}
bool CGRequestListenEventAccess(void) {
    record("input_monitoring");
    return CGPreflightListenEventAccess();
}
CFMachPortRef CGEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place,
    CGEventTapOptions options, CGEventMask events, CGEventTapCallBack callback, void *info) {
    return NULL;
}
void CGEventPost(CGEventTapLocation tap, CGEventRef event) { abort(); }
''')
        obj = work / "permissions.o"
        cls.binary = work / "typeless-autosend"
        subprocess.run(["clang", "-c", str(stub), "-o", str(obj)], check=True)
        subprocess.run(["swiftc", *map(str, sorted(ROOT.glob("*.swift"))),
                        str(obj), "-o", str(cls.binary), "-lsqlite3"], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="autosend-permissions-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.executable = self.directory / "typeless-autosend"
        shutil.copy2(self.binary, self.executable)
        config = self.directory / "config.json"
        config.write_text(json.dumps({"apps": []}))
        database = self.directory / "history.db"
        with sqlite3.connect(database) as conn:
            conn.executescript((ROOT / "tests/schema.sql").read_text())
        self.requests = self.directory / "requests.log"
        self.environment = dict(os.environ, TYPELESS_AUTOSEND_CONFIG=str(config),
                                TYPELESS_DB=str(database),
                                PERMISSION_TEST_REQUESTS=str(self.requests))
        for name in ("TYPELESS_DRY_RUN", "PERMISSION_TEST_AX_GRANTED", "PERMISSION_TEST_INPUT_GRANTED"):
            self.environment.pop(name, None)

    def run_daemon(self):
        status = self.directory / "runtime-status.json"
        status.unlink(missing_ok=True)
        with (self.directory / "daemon.log").open("w") as log:
            process = subprocess.Popen([str(self.executable)], env=self.environment,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 5
                while not status.exists():
                    self.assertIsNone(process.poll(), (self.directory / "daemon.log").read_text())
                    self.assertLess(time.monotonic(), deadline, "Daemon did not publish startup status")
                    time.sleep(0.02)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)

    def test_input_monitoring_is_not_requested_separately(self):
        self.environment["PERMISSION_TEST_AX_GRANTED"] = "1"
        (self.directory / ".access-prompted").touch()
        self.run_daemon()
        self.assertFalse(self.requests.exists())

    def test_restart_does_not_repeat_a_denied_permission_request(self):
        self.run_daemon()
        self.run_daemon()
        self.assertEqual(self.requests.read_text().splitlines(), ["accessibility"])

    def test_granted_permissions_do_not_prompt(self):
        self.environment.update(PERMISSION_TEST_AX_GRANTED="1", PERMISSION_TEST_INPUT_GRANTED="1")
        self.run_daemon()
        self.assertFalse(self.requests.exists())

    def test_missing_permissions_only_request_accessibility(self):
        self.run_daemon()
        self.assertEqual(self.requests.read_text().splitlines(), ["accessibility"])

    def test_cli_and_simulated_service_do_not_request_permissions(self):
        cli = subprocess.run([str(self.executable), "delay", "get"], env=self.environment,
                             capture_output=True, text=True, timeout=5)
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.environment["TYPELESS_DRY_RUN"] = "1"
        self.run_daemon()
        self.assertFalse(self.requests.exists())


if __name__ == "__main__":
    unittest.main()
