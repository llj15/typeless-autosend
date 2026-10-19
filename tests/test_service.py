"""Service behavior: single-instance lock, records whose text arrives late, empty config log, list-apps."""
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *  # noqa: E402,F403

SLACK = "com.tinyspeck.slackmacgap"


def copy_binary(subdir):
    d = f"{WORK}/{subdir}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copy(BIN, f"{d}/typeless-autosend")
    return d, f"{d}/typeless-autosend"


print("Single-instance lock")
d, b = copy_binary("lock")
conn = newdb(f"{WORK}/h.db")
row(conn, "base")
first = start(b, f"{WORK}/h.db", f"{WORK}/h1.log")
time.sleep(1)
second = start(b, f"{WORK}/h.db", f"{WORK}/h2.log", TYPELESS_LOCK_WAIT="1")
time.sleep(2.2)
check("a second instance gives up and exits with status 0", second.poll() == 0, f"(poll={second.poll()})")
check("and says why", "another instance is already running" in text(f"{WORK}/h2.log"))
check("the first instance keeps running", first.poll() is None)
r = subprocess.run([b, "doctor"], env=dict(os.environ, TYPELESS_DB=f"{WORK}/h.db", TYPELESS_AUTOSEND_CONFIG=f"{WORK}/none.json"),
                   capture_output=True, text=True)
check("doctor does not need the lock", "typeless-autosend doctor" in r.stdout)
row(conn, "handled_once")
time.sleep(0.8)
check("only the lock holder handles records", text(f"{WORK}/h1.log").count("would enter id=handled_once ") == 1)
stop(first)
stop(second)
third = start(b, f"{WORK}/h.db", f"{WORK}/h3.log")
time.sleep(1)
check("the lock is released when the holder exits", third.poll() is None)
stop(third)
conn.close()

print("An old instance that is still shutting down: the new one waits for the lock and takes over")
d, b = copy_binary("lock-takeover")
conn = newdb(f"{WORK}/h2.db")
row(conn, "base")
old = start(b, f"{WORK}/h2.db", f"{d}/old.log")
time.sleep(1)
new = start(b, f"{WORK}/h2.db", f"{d}/new.log")
time.sleep(0.8)
stop(old)
time.sleep(2)
check("the new instance is running", new.poll() is None)
check("and it has started", "started (dry run)" in text(f"{d}/new.log"))
stop(new)
conn.close()

print("With a live holder, the default wait is about 5 seconds")
d, b = copy_binary("lock-wait")
conn = newdb(f"{WORK}/h3.db")
row(conn, "base")
holder = start(b, f"{WORK}/h3.db", f"{d}/a.log")
time.sleep(1)
waiter = start(b, f"{WORK}/h3.db", f"{d}/b.log")
t0 = time.time()
try:
    waiter.wait(timeout=8)
except subprocess.TimeoutExpired:
    pass
waited = time.time() - t0
check("the waiter exits with status 0 after roughly 5 s", waiter.poll() == 0 and 4.0 <= waited <= 7.5,
      f"(rc={waiter.poll()}, waited {waited:.1f}s)")
stop(holder)
stop(waiter)
conn.close()

print("A record that turns completed before its text is written")
db, log = f"{WORK}/i.db", f"{WORK}/i.log"
conn = newdb(db)
row(conn, "base")
p = start(BIN, db, log)
time.sleep(1)
row(conn, "late_text", text="")
time.sleep(0.5)
conn.execute("update history_v2 set refined_text='hello', updated_at=? where id='late_text'", (now(),))
conn.commit()
time.sleep(0.8)
stop(p)
conn.close()
check("it fires once the text shows up", outcome(log, "late_text") == "enter")
db, log = f"{WORK}/i2.db", f"{WORK}/i2.log"
conn = newdb(db)
row(conn, "base")
p = start(BIN, db, log)
time.sleep(1)
row(conn, "always_blank", text="")
time.sleep(1.5)
stop(p)
conn.close()
check("a record whose text stays empty never fires", outcome(log, "always_blank") != "enter")

print("An empty apps list is explained in the log")
cfg = f"{WORK}/empty-apps.json"
open(cfg, "w").write(json.dumps({"apps": []}))
db, log = f"{WORK}/j.db", f"{WORK}/j.log"
conn = newdb(db)
row(conn, "base")
p = start(BIN, db, log, cfg=cfg, fake_front=SLACK)
time.sleep(1)
row(conn, "nothing_enabled")
time.sleep(0.8)
stop(p)
conn.close()
check("logs 'config has no apps' and does not press Return",
      "config has no apps" in text(log) and outcome(log, "nothing_enabled") != "enter")

print("list-apps")
regular = subprocess.run([BIN, "list-apps"], capture_output=True, text=True).stdout.splitlines()
everything = subprocess.run([BIN, "list-apps", "--all"], capture_output=True, text=True).stdout.splitlines()
check("--all lists at least as many apps as the default", len(everything) >= len(regular) > 0,
      f"(default {len(regular)}, --all {len(everything)})")
finish()
