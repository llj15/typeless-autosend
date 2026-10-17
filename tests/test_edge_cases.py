"""Edge cases around the database: cloud backfill, WAL mode, incompatible schemas, bursts, default config path."""
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *  # noqa: E402,F403

SLACK = "com.tinyspeck.slackmacgap"

print("Cloud backfill must not push a local record out of the 'recent records' window")
db, log = f"{WORK}/e1.db", f"{WORK}/e1.log"
conn = newdb(db)
row(conn, "base")
p = start(BIN, db, log)
time.sleep(1)
row(conn, "local", status=None, text=None)  # a local dictation: placeholder row inserted when recording starts
conn.executemany(
    f"insert into history_v2({COLS}) values(?,?,?,?,?,?,'x',1)",
    [(f"cloud{i}", "completed", "voice_transcript", "x", now(), now()) for i in range(25)])
conn.commit()
time.sleep(0.6)
conn.execute("update history_v2 set status='completed', refined_text='hello', updated_at=? where id='local'", (now(),))
conn.commit()
time.sleep(0.8)
stop(p)
conn.close()
check("the local record still triggers", outcome(log, "local") == "enter")
check("cloud records never trigger", "id=cloud" not in text(log))

print("WAL mode: writes land in the -wal file and the main file does not change")
db, log = f"{WORK}/e2.db", f"{WORK}/e2.log"
conn = newdb(db, wal=True)
row(conn, "base")
p = start(BIN, db, log)
time.sleep(1)
row(conn, "wal_write")
time.sleep(0.8)
stop(p)
conn.close()
check("a write that only touches the -wal file is detected", outcome(log, "wal_write") == "enter")

print("Incompatible schema: reason is logged once, service recovers when the schema is fixed")
db, log = f"{WORK}/e3.db", f"{WORK}/e3.log"
conn = newdb(db, ddl="create table history_v2(id text primary key, mode text, status text, updated_at text)")
p = start(BIN, db, log)
time.sleep(3.5)
t = text(log)
check("one 'db read failing' line naming the missing column",
      t.count("db read failing") == 1 and "missing columns: refined_text" in t)
conn.execute("alter table history_v2 add column refined_text text")
conn.commit()
time.sleep(1.6)
check("recovers and builds the baseline once the column exists",
      "db read recovered" in text(log) and "baseline ready" in text(log))
conn.execute("insert into history_v2(id,status,mode,refined_text,updated_at) values('after_fix','completed','voice_transcript','x',?)", (now(),))
conn.commit()
time.sleep(0.8)
stop(p)
check("works normally after recovery", outcome(log, "after_fix") == "enter")
conn.close()

print("Older Typeless without the synced_from_cloud column")
db, log = f"{WORK}/e4.db", f"{WORK}/e4.log"
conn = newdb(db, ddl="create table history_v2(id text primary key, mode text, status text, refined_text text, updated_at text)")
conn.execute("insert into history_v2 values('base','voice_transcript','completed','x',?)", (now(),))
conn.commit()
p = start(BIN, db, log)
time.sleep(1)
conn.execute("insert into history_v2 values('no_cloud_col','voice_transcript','completed','x',?)", (now(),))
conn.commit()
time.sleep(0.8)
stop(p)
conn.close()
check("still works without the column", outcome(log, "no_cloud_col") == "enter")

print("Two records completing in the same poll press Return only once")
db, log = f"{WORK}/e5.db", f"{WORK}/e5.log"
conn = newdb(db)
row(conn, "base")
p = start(BIN, db, log)
time.sleep(1)
conn.executemany(
    f"insert into history_v2({COLS}) values(?,?,?,?,?,?,'x',0)",
    [(f"burst{i}", "completed", "voice_transcript", "x", now(), now()) for i in range(2)])
conn.commit()
time.sleep(1)
stop(p)
conn.close()
t = text(log)
check("exactly one 'would enter'", t.count("would enter") == 1, f"(got {t.count('would enter')})")
check("the other record is logged as coalesced", t.count("coalesced") == 1)

print("The default config path is next to the executable, also when started through a symlink")
direct = f"{WORK}/default-config"
shutil.rmtree(direct, ignore_errors=True)
os.makedirs(direct)
os.makedirs(f"{WORK}/links", exist_ok=True)
shutil.copy(BIN, f"{direct}/typeless-autosend")
open(f"{direct}/config.json", "w").write(f'{{"apps": ["{SLACK}"], "delaySeconds": 0}}')
link = f"{WORK}/links/via-symlink"
if os.path.lexists(link):
    os.remove(link)
os.symlink(f"{direct}/typeless-autosend", link)
# Ambient old/new overrides must never escape the dry-run test sandbox.
foreign = f"{WORK}/foreign-config"
os.makedirs(foreign, exist_ok=True)
open(f"{foreign}/config.json", "w").write('{"apps": []}')
saved_overrides = {key: os.environ.get(key) for key in ("TYPELESS_AUTOENTER_CONFIG", "TYPELESS_AUTOSEND_CONFIG")}
for key in saved_overrides:
    os.environ[key] = f"{foreign}/config.json"
for how, binary in (("started directly", f"{direct}/typeless-autosend"), ("started via symlink", link)):
    db, log = f"{WORK}/e6.db", f"{WORK}/e6.log"
    conn = newdb(db)
    row(conn, "base")
    p = start(binary, db, log, fake_front=SLACK)
    time.sleep(1)
    row(conn, "uses_sibling_config")
    time.sleep(0.8)
    stop(p)
    conn.close()
    check(f"{how}: reads config.json from the executable's directory", outcome(log, "uses_sibling_config") == "enter")
check("ambient configuration overrides cannot write runtime state outside the daemon fixture",
      not os.path.exists(f"{foreign}/runtime-status.json"))
for key, value in saved_overrides.items():
    if value is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = value

print("Unknown subcommand")
r = subprocess.run([BIN, "bogus"], capture_output=True, text=True)
check("exits with status 2 and points to help", r.returncode == 2 and "--help" in r.stderr)
finish()
