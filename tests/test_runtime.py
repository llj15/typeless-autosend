"""Daemon seam: real SQLite/config, simulated macOS events, observable dry-run sends/skips."""
import json
import datetime as dt
import os
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
BINARY = Path(os.environ.get("TYPELESS_TEST_BINARY", HERE / ".work/typeless-autosend"))
APP = "com.example.editor"
OTHER = "com.example.chat"


class Runtime(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="autosend-runtime-")
        self.directory = Path(self.scratch.name)
        self.binary = self.directory / "typeless-autosend"
        shutil.copy2(BINARY, self.binary)
        self.config = self.directory / "config.json"
        self.events = self.directory / "events.jsonl"
        self.events.touch()
        self.log = self.directory / "daemon.log"
        self.db = sqlite3.connect(self.directory / "typeless.db")
        self.db.executescript((HERE / "schema.sql").read_text())
        self.configure()
        self.process = None

    def tearDown(self):
        if self.process:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.db.close()
        self.scratch.cleanup()

    def configure(self, **settings):
        data = {"apps": [APP, OTHER], **settings}
        temp = self.config.with_suffix(".tmp")
        temp.write_text(json.dumps(data))
        temp.replace(self.config)

    def start(self, **extra):
        environment = dict(os.environ, TYPELESS_DB=str(self.directory / "typeless.db"),
                           TYPELESS_AUTOSEND_CONFIG=str(self.config), TYPELESS_DRY_RUN="1",
                           TYPELESS_FAKE_FRONT=APP, TYPELESS_TEST_EVENTS=str(self.events), **extra)
        self.output = self.log.open("w")
        self.addCleanup(self.output.close)
        self.process = subprocess.Popen([self.binary], env=environment, stdout=self.output,
                                        stderr=subprocess.STDOUT)
        self.wait_for("baseline ready")

    def complete(self, identifier):
        timestamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.db.execute("insert into history_v2(id,status,mode,refined_text,created_at,updated_at,app_version,synced_from_cloud) values(?, 'completed','voice_transcript','hello',?,?, 'x',0)",
                        (identifier, timestamp, timestamp))
        self.db.commit()

    def event(self, kind, **fields):
        with self.events.open("a") as handle:
            handle.write(json.dumps({"type": kind, **fields}) + "\n")

    def commands_while_daemon_suspended(self, *commands):
        # Model a busy daemon so a short CLI state transition cannot rely on lucky poll timing.
        self.process.send_signal(signal.SIGSTOP)
        try:
            for command in commands:
                result = subprocess.run([self.binary, *command], capture_output=True, text=True,
                    env=dict(os.environ, TYPELESS_AUTOSEND_CONFIG=str(self.config)), timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        finally:
            self.process.send_signal(signal.SIGCONT)

    def text(self):
        return self.log.read_text()

    def wait_for(self, value, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if value in self.text():
                return
            if self.process and self.process.poll() is not None:
                self.fail(f"daemon exited: {self.text()}")
            time.sleep(0.02)
        self.fail(f"did not observe {value!r}: {self.text()}")

    def assert_no_send(self, identifier, seconds=0.3):
        time.sleep(seconds)
        self.assertNotIn(f"would enter id={identifier} ", self.text())

    def test_default_waits_one_second_after_paste_buffer(self):
        self.start()
        self.complete("default-delay")
        self.assert_no_send("default-delay", seconds=0.75)
        self.wait_for("would enter id=default-delay ")

    def test_per_app_override_keeps_the_paste_buffer(self):
        self.configure(delaySeconds=4, appDelaySeconds={APP: 0.2})
        self.start()
        self.complete("override")
        self.assert_no_send("override", seconds=0.25)
        self.wait_for("would enter id=override ", timeout=0.6)

    def test_fn_cancels_old_attempt_and_new_completion_gets_fresh_countdown(self):
        self.start()
        self.complete("old")
        time.sleep(0.25)
        self.event("keyboard", origin="physical", key="fn")
        self.wait_for("skip id=old ")
        self.complete("new")
        self.assert_no_send("new", seconds=0.75)
        self.wait_for("would enter id=new ")
        self.assert_no_send("old")

    def test_switching_between_enabled_apps_cancels_even_when_switching_back(self):
        self.start()
        self.complete("app-switch")
        time.sleep(0.25)
        self.event("focus", app=OTHER)
        self.event("focus", app=APP)
        self.wait_for("skip id=app-switch ")
        self.assert_no_send("app-switch", seconds=1.1)

    def test_mouse_click_cancels_only_when_it_changes_selection_or_focus(self):
        self.configure(delaySeconds=0.5)
        self.start()
        self.complete("unchanged-click")
        time.sleep(0.25)
        self.event("mouse")
        self.wait_for("would enter id=unchanged-click ")
        self.complete("caret-click")
        time.sleep(0.25)
        self.event("mouse", caret=3)
        self.wait_for("skip id=caret-click ")
        self.assert_no_send("caret-click", seconds=0.65)

    def test_pause_cancels_pending_and_consumes_completed_rows(self):
        self.start()
        self.complete("pause-pending")
        time.sleep(0.25)
        self.configure(paused=True)
        self.wait_for("skip id=pause-pending ", timeout=0.4)
        self.complete("while-paused")
        self.wait_for("skip id=while-paused ")
        self.configure(paused=False)
        self.assert_no_send("while-paused", seconds=1.3)

    def test_missing_system_capability_skips_this_attempt_and_retries_next_transcript(self):
        self.configure(delaySeconds=0.2)
        self.event("capability", inputMonitoring=False)
        self.start()
        self.complete("cannot-listen")
        self.wait_for("skip id=cannot-listen ")
        self.event("capability", inputMonitoring=True, focusReadable=False)
        self.complete("cannot-inspect")
        self.wait_for("skip id=cannot-inspect ")
        self.event("capability", focusReadable=True)
        self.complete("recovered")
        self.wait_for("would enter id=recovered ")
        self.assert_no_send("cannot-listen")
        self.assert_no_send("cannot-inspect")

    def test_selection_change_delivered_late_after_mouse_still_cancels(self):
        self.configure(delaySeconds=0.7)
        self.start()
        self.complete("late-selection")
        time.sleep(0.25)
        self.event("mouse")
        time.sleep(0.2)
        self.event("state", caret=5, selectionLength=2)
        self.wait_for("skip id=late-selection ")
        self.assert_no_send("late-selection", seconds=0.6)

    def test_secure_input_skips_and_retries_after_it_ends(self):
        self.configure(delaySeconds=0.2)
        self.event("capability", secureInput=True)
        self.start()
        self.complete("secure-input")
        self.wait_for("skip id=secure-input ")
        self.event("capability", secureInput=False)
        self.complete("secure-ended")
        self.wait_for("would enter id=secure-ended ")
        self.assert_no_send("secure-input")

    def test_typeless_injection_is_ignored_but_every_other_keyboard_event_cancels(self):
        self.configure(delaySeconds=0.35)
        self.start()
        self.complete("injected")
        time.sleep(0.2)
        self.event("keyboard", origin="typeless", key="v")
        self.event("keyboard", origin="typeless-helper-verified", key="shift")
        self.wait_for("would enter id=injected ")
        for key in ["letter", "left-arrow", "shift", "control", "option", "command", "unknown-source"]:
            with self.subTest(key=key):
                self.complete(key)
                time.sleep(0.2)
                self.event("keyboard", origin="unknown" if key == "unknown-source" else "physical", key=key)
                self.wait_for(f"skip id={key} ")
        time.sleep(0.6)
        for key in ["letter", "left-arrow", "shift", "control", "option", "command", "unknown-source"]:
            self.assertNotIn(f"would enter id={key} ", self.text())

    def test_window_and_input_switches_cancel_even_when_returned_before_next_poll(self):
        self.start()
        for field, original in [("window", "window-1"), ("input", "input-1")]:
            with self.subTest(field=field):
                self.complete(field)
                time.sleep(0.25)
                self.event("focus", **{field: "elsewhere"})
                self.event("focus", **{field: original})
                self.wait_for(f"skip id={field} ")
        time.sleep(1.2)
        self.assertNotIn("would enter", self.text())

    def test_removing_app_cancels_pending_permanently(self):
        self.start()
        self.complete("removed")
        time.sleep(0.25)
        self.configure(apps=[OTHER])
        self.wait_for("skip id=removed ", timeout=0.4)
        self.configure()
        self.assert_no_send("removed", seconds=1.2)

    def test_delay_edits_only_affect_the_next_attempt(self):
        self.configure(delaySeconds=0.5)
        self.start()
        self.complete("original-delay")
        time.sleep(0.25)
        self.configure(delaySeconds=1.5)
        self.wait_for("would enter id=original-delay ", timeout=0.6)
        self.complete("next-delay")
        time.sleep(0.25)
        self.configure(delaySeconds=0)
        self.assert_no_send("next-delay", seconds=0.8)
        self.wait_for("would enter id=next-delay ")

    def test_delay_beyond_scheduler_range_is_skipped_without_crashing(self):
        self.configure(delaySeconds=1e100)
        self.start()
        self.complete("unrepresentable-delay")
        self.wait_for("skip id=unrepresentable-delay ")
        self.assertIsNone(self.process.poll())
        self.assert_no_send("unrepresentable-delay")

    def test_later_completion_replaces_the_old_countdown(self):
        self.start()
        self.complete("earlier")
        time.sleep(0.45)
        self.complete("later")
        self.wait_for("skip id=earlier ")
        self.assert_no_send("later", seconds=0.7)
        self.wait_for("would enter id=later ")
        self.assert_no_send("earlier")

    def test_cli_pause_resume_between_polls_still_cancels_permanently(self):
        self.start()
        self.complete("brief-pause")
        time.sleep(0.25)
        self.commands_while_daemon_suspended(["service", "pause"], ["service", "resume"])
        self.wait_for("skip id=brief-pause ", timeout=0.4)
        self.assert_no_send("brief-pause", seconds=1.1)

    def test_cli_remove_readd_between_polls_still_cancels_permanently(self):
        self.start()
        self.complete("brief-removal")
        time.sleep(0.25)
        self.commands_while_daemon_suspended(["apps", "remove", APP], ["apps", "add", APP])
        self.wait_for("skip id=brief-removal ", timeout=0.4)
        self.assert_no_send("brief-removal", seconds=1.1)

    def test_removing_an_unrelated_app_keeps_the_current_countdown(self):
        self.configure(delaySeconds=0.6)
        self.start()
        self.complete("unrelated-removal")
        time.sleep(0.25)
        self.commands_while_daemon_suspended(["apps", "remove", OTHER])
        self.wait_for("would enter id=unrelated-removal ")

    def test_invalid_caret_metadata_skips_until_valid_selection_is_available(self):
        self.configure(delaySeconds=0.2)
        self.start()
        for index, (caret, length) in enumerate([(-1, 0), (0, -1), (2**63 - 1, 0), (0, 2**63 - 1)]):
            with self.subTest(caret=caret, selectionLength=length):
                identifier = f"invalid-caret-{index}"
                self.event("state", caret=caret, selectionLength=length)
                self.complete(identifier)
                self.wait_for(f"skip id={identifier} ")
                self.assertNotIn(f"would enter id={identifier} ", self.text())
        self.event("state", caret=0, selectionLength=0)
        self.complete("valid-empty-selection")
        self.wait_for("would enter id=valid-empty-selection ")

    def test_completion_while_paused_is_consumed_even_if_daemon_was_busy(self):
        self.configure(delaySeconds=0.2)
        self.start()
        self.process.send_signal(signal.SIGSTOP)
        try:
            pause = subprocess.run([self.binary, "service", "pause"], capture_output=True, text=True,
                env=dict(os.environ, TYPELESS_AUTOSEND_CONFIG=str(self.config)), timeout=5)
            self.assertEqual(pause.returncode, 0, pause.stdout + pause.stderr)
            self.complete("completed-while-paused")
            resume = subprocess.run([self.binary, "service", "resume"], capture_output=True, text=True,
                env=dict(os.environ, TYPELESS_AUTOSEND_CONFIG=str(self.config)), timeout=5)
            self.assertEqual(resume.returncode, 0, resume.stdout + resume.stderr)
        finally:
            self.process.send_signal(signal.SIGCONT)
        self.wait_for("skip id=completed-while-paused ")
        self.complete("completed-after-resume")
        self.wait_for("would enter id=completed-after-resume ")
        self.assertNotIn("would enter id=completed-while-paused ", self.text())


if __name__ == "__main__":
    unittest.main()
