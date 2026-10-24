"""Database cancellation unit seam: temporary SQLite/config plus simulated events only."""
import datetime as dt
import json
import signal
import time
import unittest

import test_runtime as runtime


class DictationUpdates(unittest.TestCase):
    # Reuse the daemon fixture without inheriting its separate behavior suite.
    setUp = runtime.Runtime.setUp
    tearDown = runtime.Runtime.tearDown
    configure = runtime.Runtime.configure
    complete = runtime.Runtime.complete
    event = runtime.Runtime.event
    text = runtime.Runtime.text
    wait_for = runtime.Runtime.wait_for
    wait_pending_file = runtime.Runtime.wait_pending_file
    assert_no_send = runtime.Runtime.assert_no_send

    def start(self, **extra):
        home = self.directory / "home"
        home.mkdir()
        runtime.Runtime.start(self, HOME=str(home), **extra)

    def insert(self, identifier, status=None, text=None, cloud=0, mode="voice_transcript", offset=0):
        stamp = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=offset)).isoformat(
            timespec="milliseconds").replace("+00:00", "Z")
        self.db.execute("insert into history_v2(id,status,mode,refined_text,created_at,updated_at,app_version,synced_from_cloud) values(?,?,?,?,?,?,'x',?)",
                        (identifier, status, mode, text, stamp, stamp, cloud))
        self.db.commit()

    def arm(self, identifier="old"):
        self.configure(delaySeconds=0.8)
        self.start()
        self.complete(identifier)
        self.wait_pending_file()

    def test_null_status_new_record_cancels_before_countdown(self):
        self.arm()
        self.insert("recording")
        self.wait_for("skip id=old superseded by newer local dictation", timeout=0.5)
        self.assert_no_send("old", seconds=0.95)

    def test_noncompleted_record_cancels_regardless_of_mode(self):
        self.arm()
        self.insert("new-command", status="processing", mode="voice_command")
        self.wait_for("skip id=old superseded by newer local dictation", timeout=0.5)
        self.assert_no_send("old", seconds=0.95)

    def test_cloud_record_does_not_cancel(self):
        self.arm()
        self.insert("cloud", cloud=1, offset=-3600)
        self.wait_for("would enter id=old ")
        self.assertNotIn("skip id=old ", self.text())

    def test_existing_record_update_does_not_cancel(self):
        self.insert("existing", offset=-3600)
        self.arm()
        self.db.execute("update history_v2 set updated_at=? where id='existing'",
                        (dt.datetime.now(dt.timezone.utc).isoformat(),))
        self.db.commit()
        self.wait_for("would enter id=old ")

    def test_completed_and_new_record_in_same_batch_never_arms_old(self):
        self.configure(delaySeconds=0.4)
        self.start()
        self.process.send_signal(signal.SIGSTOP)
        try:
            self.complete("old-completed")
            self.insert("new-recording")
        finally:
            self.process.send_signal(signal.SIGCONT)
        self.wait_for("skip id=old-completed superseded by newer local dictation")
        self.assert_no_send("old-completed", seconds=0.7)

    def test_only_latest_completed_in_batch_can_send(self):
        self.configure(delaySeconds=0.3)
        self.start()
        self.process.send_signal(signal.SIGSTOP)
        try:
            self.complete("first")
            self.complete("latest")
        finally:
            self.process.send_signal(signal.SIGCONT)
        self.wait_for("would enter id=latest ")
        self.assert_no_send("first")
        self.assertIn("skip id=first coalesced", self.text())

    def test_late_completion_of_older_record_does_not_replace_newer_pending(self):
        self.insert("older-recording")
        self.arm("newer-completed")
        stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.db.execute("update history_v2 set status='completed',refined_text='hello',updated_at=? where id='older-recording'", (stamp,))
        self.db.commit()
        self.wait_for("would enter id=newer-completed ")
        self.assert_no_send("older-recording")

    def test_cancelled_placeholder_can_later_complete_and_send_once(self):
        self.arm()
        self.insert("recording")
        self.wait_for("skip id=old superseded by newer local dictation")
        stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.db.execute("update history_v2 set status='completed',refined_text='hello',updated_at=? where id='recording'", (stamp,))
        self.db.commit()
        self.wait_for("would enter id=recording ")
        self.assert_no_send("old")
        self.assertEqual(self.text().count("would enter id=recording "), 1)

    def test_completed_before_paste_retries_without_database_change(self):
        self.configure(apps=[runtime.APP], delaySeconds=0.2)
        self.start(TYPELESS_TEST_REQUIRE_PASTE="1")
        self.complete("completed-before-paste")
        self.assert_no_send("completed-before-paste", seconds=0.65)
        self.event("typeless_paste")
        self.event("state", text="hello", caret=5)
        self.event("focus", app=runtime.OTHER)
        self.wait_for("would enter id=completed-before-paste destination=original-pid")
        self.assertNotIn("not in whitelist", self.text())

    def test_unpasted_completion_expires_without_replay(self):
        self.configure(delaySeconds=0.1)
        self.start(TYPELESS_TEST_REQUIRE_PASTE="1")
        self.insert("expired", status="completed", text="hello", offset=-9)
        self.wait_for("skip id=expired mode=voice_transcript", timeout=2)
        self.event("typeless_paste")
        self.event("state", text="hello", caret=5)
        self.assert_no_send("expired", seconds=0.5)

    def test_unconsumed_paste_for_paused_record_cannot_bind_next_completion(self):
        self.configure(paused=True, delaySeconds=0.2)
        self.start(TYPELESS_TEST_REQUIRE_PASTE="1")
        self.complete("paused")
        self.wait_for("skip id=paused autosend paused")
        self.event("typeless_paste")
        self.event("state", text="hello", caret=5)
        time.sleep(0.2)
        self.configure(delaySeconds=0.2)
        self.complete("next-completed")
        self.assert_no_send("next-completed", seconds=0.65)
        self.event("typeless_paste")
        self.event("state", text="hellohello", caret=10)
        self.wait_for("would enter id=next-completed ")

    def test_late_old_paste_cannot_bind_new_incomplete_record(self):
        self.configure(delaySeconds=0.2)
        self.start(TYPELESS_TEST_REQUIRE_PASTE="1")
        self.complete("old-completed")
        self.insert("new-recording")
        self.wait_for("skip id=old-completed superseded by newer local dictation")
        # The old transcript's late paste arrives while the latest recording
        # still has NULL status. It must not acquire that newer record's ID.
        self.event("typeless_paste")
        self.event("state", text="hello", caret=5)
        time.sleep(0.25)
        stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        self.db.execute("update history_v2 set status='completed',refined_text='hello',updated_at=? where id='new-recording'", (stamp,))
        self.db.commit()
        self.assert_no_send("new-recording", seconds=0.65)
        self.assertFalse(json.loads((self.directory / "runtime-status.json").read_text())["pending"])
        # Only this recording's own paste may bind and arm its countdown.
        self.event("focus", input="input-2", text="", caret=0)
        self.event("typeless_paste")
        self.event("state", text="hello", caret=5)
        self.wait_for("would enter id=new-recording ")
        self.assertEqual(self.text().count("would enter id=new-recording "), 1)
        self.assert_no_send("old-completed")

    def test_cloud_backfill_does_not_change_paste_record_identity(self):
        self.configure(delaySeconds=0.2)
        self.start(TYPELESS_TEST_REQUIRE_PASTE="1")
        self.complete("local-paste")
        self.insert("cloud-backfill", status="completed", text="hello", cloud=1)
        self.event("typeless_paste")
        self.event("state", text="hello", caret=5)
        self.wait_for("would enter id=local-paste ")
        self.assert_no_send("cloud-backfill")

    def test_new_record_prevents_send_when_departure_arrives_in_same_poll(self):
        self.arm()
        time.sleep(0.25)  # Let the simulated paste settle before a departure.
        self.process.send_signal(signal.SIGSTOP)
        try:
            self.insert("recording")
            self.event("focus", app=runtime.OTHER)
        finally:
            self.process.send_signal(signal.SIGCONT)
        self.wait_for("skip id=old ", timeout=0.5)
        self.assert_no_send("old", seconds=0.95)


if __name__ == "__main__":
    unittest.main()
