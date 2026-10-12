"""Database-side behavior: which records make the service press Return. The frontmost-app check always passes here."""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *  # noqa: E402,F403

db, log = f"{WORK}/f.db", f"{WORK}/full.log"
conn = newdb(db)
row(conn, "old1", created=now(-600), updated=now(-590))  # baseline: never triggers
p = start(BIN, db, log)
time.sleep(1)


def step(fn):
    fn()
    time.sleep(0.6)


step(lambda: row(conn, "p1", status=None, text=None))  # recording started: placeholder row
step(lambda: (conn.execute("update history_v2 set status='completed', refined_text='hello', updated_at=? where id='p1'", (now(),)), conn.commit()))
step(lambda: row(conn, "voice_command", mode="voice_command"))
step(lambda: row(conn, "dismissed", status="dismissed"))
step(lambda: row(conn, "blank", text=""))
step(lambda: row(conn, "from_cloud", cloud=1))
step(lambda: row(conn, "stale", created=now(-600), updated=now(-590)))
step(lambda: row(conn, "long_recording", created=now(-600)))  # old created_at, fresh updated_at
step(lambda: row(conn, "translation", mode="voice_translation"))
step(lambda: (conn.execute("update history_v2 set updated_at=?, sync_status='synced' where id='p1'", (now(),)), conn.commit()))
step(lambda: row(conn, "slightly_in_future", updated=now(0.1)))
# Typeless holds a write lock for 1.5 s while inserting; the record must still be picked up afterwards.
locker = sqlite3.connect(db, isolation_level=None)
locker.execute("begin exclusive")
locker.execute(
    f"insert into history_v2({COLS}) values('during_lock','completed','voice_transcript','x',?,?,'x',0)", (now(), now()))
time.sleep(1.5)
locker.execute("commit")
locker.close()
time.sleep(1)
stop(p)
conn.close()

expected = {
    "p1": "enter", "voice_command": "skip", "dismissed": "none", "blank": "noenter", "from_cloud": "none",
    "stale": "skip", "long_recording": "enter", "translation": "enter", "slightly_in_future": "enter",
    "during_lock": "enter",
}
for rid, expect in expected.items():
    got = outcome(log, rid)
    check(rid, got != "enter" if expect == "noenter" else got == expect, f"(expect {expect}, got {got})")
fired = text(log).count("would enter id=p1 ")
check("a later update of an already-handled record does not fire again", fired == 1, f"(fired {fired} time(s))")
finish()
