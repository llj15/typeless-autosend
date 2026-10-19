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

    def service_status(self):
        result = subprocess.run([self.binary, "service", "status"],
            env=dict(os.environ, TYPELESS_AUTOSEND_CONFIG=str(self.config)),
            capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def wait_status(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.service_status()
            if predicate(status):
                return status
            time.sleep(0.04)
        self.fail(f"status did not satisfy expectation: {status}")

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

    def test_tap_timeout_cancels_old_countdown_and_recovers_for_new_transcript(self):
        self.configure(delaySeconds=0.6)
        self.start()
        self.complete("tap-interrupted")
        time.sleep(0.2)
        self.event("monitoring", tap="timeout")
        self.wait_for("skip id=tap-interrupted input monitoring interrupted")
        self.assert_no_send("tap-interrupted", seconds=0.8)
        self.complete("after-tap-recovery")
        self.wait_for("would enter id=after-tap-recovery ")
        self.assertEqual(self.process.poll(), None)

    def test_listener_recovers_from_disabled_invalid_missing_tap_and_missing_source(self):
        self.configure(delaySeconds=0.35)
        self.start()
        for fault in ("user_disabled", "invalid", "missing", "source_missing"):
            with self.subTest(fault=fault):
                self.complete(fault)
                time.sleep(0.2)
                self.event("monitoring", tap=fault)
                self.wait_for(f"skip id={fault} ")
                self.assert_no_send(fault, seconds=0.5)
                self.complete(f"recovered-{fault}")
                self.wait_for(f"would enter id=recovered-{fault} ")

    def test_failed_recovery_stays_unavailable_and_retries_at_most_once_per_second(self):
        self.configure(delaySeconds=0.2)
        self.event("monitoring", tap="timeout", enableSucceeds=False, createSucceeds=False)
        self.start()
        failed = self.wait_status(lambda status: status.get("inputMonitoringRecoveryAttempts") == 1)
        self.assertFalse(failed["inputMonitoringAvailable"])
        self.assertEqual(failed["inputMonitoringReason"], "tap_missing")
        self.assertFalse(failed["inputTapPresent"])
        self.assertFalse(failed["inputTapSourcePresent"])
        time.sleep(0.3)
        self.assertEqual(self.service_status()["inputMonitoringRecoveryAttempts"], 1)
        self.complete("during-recovery-failure")
        self.wait_for("skip id=during-recovery-failure ")
        self.event("monitoring", createSucceeds=True)
        recovered = self.wait_status(lambda status: status["inputMonitoringAvailable"])
        self.assertIsNone(recovered["inputMonitoringReason"])
        self.assertTrue(recovered["inputTapValid"])
        self.assertTrue(recovered["inputTapSourcePresent"])
        self.assertTrue(recovered["inputTapEnabled"])
        self.assertGreaterEqual(recovered["inputMonitoringRecoveryAttempts"], 2)
        self.complete("after-recovery-retry")
        self.wait_for("would enter id=after-recovery-retry ")
        self.assert_no_send("during-recovery-failure")

    def test_failed_reenable_falls_back_to_recreate_and_still_cancels_old_attempt(self):
        self.configure(delaySeconds=0.5)
        self.start()
        self.complete("failed-enable-pending")
        self.wait_status(lambda status: status["pending"])
        self.event("monitoring", tap="timeout", enableSucceeds=False, createSucceeds=True)
        self.wait_for("skip id=failed-enable-pending ")
        restored = self.wait_status(lambda status: status.get("inputMonitoringRecoveryAttempts") == 1)
        self.assertTrue(restored["inputMonitoringAvailable"])
        self.assertTrue(restored["inputTapValid"])
        self.assertTrue(restored["inputTapSourcePresent"])
        self.complete("fresh-after-recreate")
        self.wait_for("would enter id=fresh-after-recreate ")
        self.assert_no_send("failed-enable-pending")

    def test_completion_unread_during_outage_is_not_replayed_when_monitor_recovers(self):
        self.configure(delaySeconds=0.2)
        self.start()
        self.process.send_signal(signal.SIGSTOP)
        try:
            self.event("monitoring", tap="timeout")
            self.complete("completed-inside-outage")
        finally:
            self.process.send_signal(signal.SIGCONT)
        self.wait_for("skip id=completed-inside-outage ")
        self.assert_no_send("completed-inside-outage", seconds=0.7)
        self.wait_status(lambda status: status["inputMonitoringAvailable"])
        self.complete("truly-new-after-recovery")
        self.wait_for("would enter id=truly-new-after-recovery ")

    def test_recovery_inside_attempt_after_database_wait_does_not_bypass_recovery_cutoff(self):
        self.configure(delaySeconds=0.2)
        self.event("monitoring", tap="invalid", createSucceeds=False)
        self.start()
        failed = self.wait_status(lambda status: status.get("inputMonitoringRecoveryAttempts") == 1)
        first_tick = dt.datetime.fromisoformat(failed["updatedAt"].replace("Z", "+00:00")).timestamp()
        self.process.send_signal(signal.SIGSTOP)
        try:
            self.event("monitoring", createSucceeds=True)
            self.complete("unread-before-attempt-recovery")
            self.db.execute("BEGIN EXCLUSIVE")
            remaining = first_tick + 0.9 - time.time()
            if remaining > 0:
                time.sleep(remaining)
        finally:
            self.process.send_signal(signal.SIGCONT)
        # The SQLite boundary holds the poll just below the one-second retry
        # deadline, then lets beginAttempt run just after it.
        time.sleep(0.18)
        self.db.commit()
        self.wait_for("skip id=unread-before-attempt-recovery ")
        self.assert_no_send("unread-before-attempt-recovery", seconds=0.6)
        self.wait_status(lambda status: status["inputMonitoringAvailable"])
        self.complete("new-after-attempt-recovery")
        self.wait_for("would enter id=new-after-attempt-recovery ")

    def test_permission_and_secure_input_fail_closed_without_recovery_storm_or_replay(self):
        self.configure(delaySeconds=0.5)
        self.start()
        for field, unavailable, restored, reason in (("inputMonitoring", False, True, "listen_permission_denied"),
                                                      ("secureInput", True, False, "secure_input")):
            with self.subTest(reason=reason):
                self.complete(f"pending-{reason}")
                self.wait_status(lambda status: status["pending"])
                before = self.service_status()["inputMonitoringRecoveryAttempts"]
                self.event("capability", **{field: unavailable})
                self.event("monitoring", tap="invalid", createSucceeds=False)
                failed = self.wait_status(lambda status: status.get("inputMonitoringReason") == reason)
                self.assertFalse(failed["inputMonitoringAvailable"])
                self.assertEqual(failed["inputMonitoringRecoveryAttempts"], before)
                self.complete(f"during-{reason}")
                self.wait_for(f"skip id=during-{reason} ")
                time.sleep(1.1)
                self.assertEqual(self.service_status()["inputMonitoringRecoveryAttempts"], before)
                self.event("monitoring", createSucceeds=True)
                self.event("capability", **{field: restored})
                self.wait_status(lambda status: status["inputMonitoringAvailable"])
                self.complete(f"new-{reason}")
                self.wait_for(f"would enter id=new-{reason} ")
                self.assert_no_send(f"pending-{reason}")
                self.assert_no_send(f"during-{reason}")

    def test_brief_capability_loss_and_restore_in_one_poll_never_sends_old_completion(self):
        self.configure(delaySeconds=0.6)
        self.start()
        for field, unavailable, restored in (("inputMonitoring", False, True), ("secureInput", True, False)):
            with self.subTest(field=field):
                self.complete(f"pending-brief-{field}")
                self.wait_status(lambda status: status["pending"])
                self.process.send_signal(signal.SIGSTOP)
                try:
                    self.event("capability", **{field: unavailable})
                    self.complete(f"unread-brief-{field}")
                    self.event("capability", **{field: restored})
                finally:
                    self.process.send_signal(signal.SIGCONT)
                self.wait_for(f"skip id=unread-brief-{field} ")
                self.assert_no_send(f"pending-brief-{field}", seconds=0.75)
                self.assert_no_send(f"unread-brief-{field}")
                self.wait_status(lambda status: status["inputMonitoringAvailable"])
                self.complete(f"new-brief-{field}")
                self.wait_for(f"would enter id=new-brief-{field} ")

    def test_missing_system_capability_skips_this_attempt_and_retries_next_transcript(self):
        self.configure(delaySeconds=0.2)
        self.event("capability", inputMonitoring=False)
        self.start()
        self.complete("cannot-listen")
        self.wait_for("skip id=cannot-listen ")
        self.event("capability", inputMonitoring=True, focusReadable=False)
        self.wait_status(lambda status: status["inputMonitoringAvailable"])
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
        self.wait_status(lambda status: status["inputMonitoringAvailable"])
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
