"""Shared helpers for the typeless-autosend tests. Run everything with tests/run.sh."""
import json
import datetime as dt
import os
import sqlite3
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WORK = os.path.join(HERE, ".work")  # scratch space, git-ignored, built by run.sh
BIN = os.path.join(WORK, "typeless-autosend")
COLS = "id,status,mode,refined_text,created_at,updated_at,app_version,synced_from_cloud"

_results = []


def check(name, cond, detail=""):
    _results.append(bool(cond))
    print(f"  [{'PASS' if cond else 'FAIL'}] {name} {detail}".rstrip())


def finish():
    ok = all(_results)
    print("ALL PASS" if ok else "SOME FAIL")
    sys.exit(0 if ok else 1)


def now(offset=0.0):
    t = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=offset)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def newdb(path, wal=False, ddl=None):
    """Create an empty Typeless-like database. ddl replaces the history_v2 table definition."""
    for ext in ("", "-wal", "-shm"):
        if os.path.exists(path + ext):
            os.remove(path + ext)
    conn = sqlite3.connect(path)
    if ddl:
        conn.execute(ddl)
    else:
        conn.executescript(open(os.path.join(HERE, "schema.sql")).read())
    if wal:
        conn.execute("pragma journal_mode=WAL")
        conn.execute("pragma wal_autocheckpoint=0")
    conn.commit()
    return conn


def row(conn, rid, status: "str | None" = "completed", text: "str | None" = "x", cloud=0, mode="voice_transcript",
        created=None, updated=None):
    conn.execute(
        f"insert into history_v2({COLS}) values(?,?,?,?,?,?,'x',?)",
        (rid, status, mode, text, created or now(), updated or now(), cloud),
    )
    conn.commit()


def start(binary, db, log, cfg=None, fake_front=None, **env):
    """Start the service in dry-run mode: it logs 'would enter' instead of pressing Return."""
    e = dict(os.environ, TYPELESS_DB=db, TYPELESS_DRY_RUN="1")
    e.pop("TYPELESS_AUTOSEND_CONFIG", None)
    e.pop("TYPELESS_AUTOENTER_CONFIG", None)
    e.pop("TYPELESS_FAKE_FRONT", None)
    if cfg is None and fake_front is None:
        cfg = log + ".config.json"
        fake_front = "com.test.fixture"
        with open(cfg, "w") as config_file:
            json.dump({"apps": [fake_front], "delaySeconds": 0}, config_file)
    if cfg:
        e["TYPELESS_AUTOSEND_CONFIG"] = cfg
    if fake_front:
        e["TYPELESS_FAKE_FRONT"] = fake_front
    e.update(env)
    return subprocess.Popen([binary], env=e, stdout=open(log, "w"), stderr=subprocess.STDOUT)


def stop(p):
    if p.poll() is None:
        p.terminate()
    p.wait()


def text(path):
    return open(path).read()


def outcome(log, rid):
    """What the service did with a record: 'enter', 'skip' or 'none' (never logged)."""
    t = text(log)
    if f"would enter id={rid} " in t:
        return "enter"
    if f"skip id={rid} " in t:
        return "skip"
    return "none"
