"""Whitelist behavior: config.json is the only source, it is hot-reloaded, and a missing or invalid file enables nothing."""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *  # noqa: E402,F403

GHOSTTY, SLACK = "com.mitchellh.ghostty", "com.tinyspeck.slackmacgap"


def apps(*ids):
    return json.dumps({"apps": list(ids), "delaySeconds": 0})


def run(front, cases):
    """cases: (record id, config content or None for 'no file', expected outcome). The config changes between records."""
    db, cfg, log = f"{WORK}/c.db", f"{WORK}/cfg.json", f"{WORK}/cfg-{front.split('.')[-1]}.log"
    conn = newdb(db)
    row(conn, "base")
    if os.path.exists(cfg):
        os.remove(cfg)
    p = start(BIN, db, log, cfg=cfg, fake_front=front)
    deadline = time.monotonic() + 10
    while "baseline ready" not in text(log):
        if p.poll() is not None or time.monotonic() >= deadline:
            stop(p)
            conn.close()
            raise AssertionError(f"daemon did not become ready: {text(log)}")
        time.sleep(0.02)
    for name, content, _ in cases:
        if content is None:
            if os.path.exists(cfg):
                os.remove(cfg)
        else:
            open(cfg, "w").write(content)
        row(conn, name)
        time.sleep(0.6)
    time.sleep(0.5)
    stop(p)
    conn.close()
    for name, _, expect in cases:
        got = outcome(log, name)
        check(f"frontmost={front.split('.')[-1]}: {name}", got == expect, f"(expect {expect}, got {got})")


print("Slack in front")
run(SLACK, [
    ("no_config_file", None, "skip"),
    ("listed", apps(SLACK), "enter"),  # picked up without a restart
    ("invalid_json", "{not json", "skip"),
    ("empty_apps", apps(), "skip"),
    ("apps_is_a_string", '{"apps": "x"}', "skip"),
    ("both_listed", apps(GHOSTTY, SLACK), "enter"),
    ("removed_again", apps(GHOSTTY), "skip"),  # takes effect immediately
    ("upper_case_id", apps("COM.TinySpeck.SlackMacGap"), "enter"),
    ("padded_id", apps("  com.tinyspeck.slackmacgap \n"), "enter"),
    ("prefix_only", apps("com.tinyspeck"), "skip"),  # no prefix matching
    ("no_apps_key", "{}", "skip"),
])
print("Ghostty in front")
run(GHOSTTY, [
    ("no_config_file", None, "skip"),
    ("invalid_json", "{not json", "skip"),  # a broken config means nothing is enabled
    ("empty_apps", apps(), "skip"),
    ("only_other_app", apps(SLACK), "skip"),
    ("listed", apps(GHOSTTY), "enter"),
])
finish()
