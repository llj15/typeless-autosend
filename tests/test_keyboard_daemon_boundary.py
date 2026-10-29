"""Real daemon lifecycle with isolated SQLite/config and simulated macOS APIs.

Even native Enter posting is intercepted in the library and never reaches macOS.
"""
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
from common import ROOT, WORK

source = Path(__file__).parent / "keyboard_boundary"
work = Path(WORK) / "keyboard-daemon-boundary"
work.mkdir(parents=True, exist_ok=True)
library = work / "libKeyboardBoundary.dylib"
subprocess.run([
    "clang", "-dynamiclib", str(source / "coregraphics.m"), "-o", str(library),
    "-framework", "ApplicationServices", "-framework", "Carbon", "-framework", "AppKit",
], check=True)
binary = work / "typeless-autosend"
subprocess.run(["swiftc", *(str(path) for path in sorted(Path(ROOT).glob("*.swift"))),
                "-o", str(binary), "-lsqlite3"], check=True)

with tempfile.TemporaryDirectory(prefix="autosend-native-boundary-") as scratch:
    directory = Path(scratch)
    config = directory / "config.json"
    marker = directory / "consumer-restarted"
    log = directory / "daemon.log"
    database = directory / "transcripts.db"
    connection = sqlite3.connect(database)
    connection.executescript((Path(__file__).parent / "schema.sql").read_text())
    config.write_text(json.dumps({"apps": ["com.other.editor"], "delaySeconds": 0}))
    environment = dict(os.environ, HOME=str(directory), TYPELESS_DB=str(database),
        TYPELESS_AUTOSEND_CONFIG=str(config), DYLD_INSERT_LIBRARIES=str(library),
        TYPELESS_BOUNDARY_CONSUMER_MARKER=str(marker), TYPELESS_BOUNDARY_CAPTURE_POSTS="1")
    environment.pop("TYPELESS_DRY_RUN", None)
    # Program-owned lock/runtime state must also live in this throw-away folder.
    import shutil
    daemon = directory / "typeless-autosend"
    shutil.copy2(binary, daemon)
    with log.open("w") as output:
        process = subprocess.Popen([daemon], env=environment, stdout=output, stderr=subprocess.STDOUT)
        def wait_for(needle, timeout=10):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                content = log.read_text()
                if needle in content:
                    return content
                if process.poll() is not None:
                    raise AssertionError(f"daemon exited: {content}")
                time.sleep(0.02)
            raise AssertionError(f"missing {needle!r}: {log.read_text()}")
        def complete(identifier):
            timestamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            connection.execute("insert into history_v2(id,status,mode,refined_text,created_at,updated_at,app_version,synced_from_cloud) values(?,'completed','voice_transcript','hello',?,?,'x',0)",
                               (identifier, timestamp, timestamp))
            connection.commit()
        try:
            wait_for("fixture: isolated macOS boundary loaded")
            wait_for("baseline ready")
            complete("not-whitelisted")
            wait_for("skip id=not-whitelisted front=com.test.editor not in whitelist")
            marker.touch()
            wait_for("fixture: dictation consumer restarted")
            # Let normal daemon polling observe the persistent restart while idle.
            time.sleep(0.25)
            config.write_text(json.dumps({"apps": ["com.test.editor"], "delaySeconds": 0}))
            complete("fresh-after-skip")
            result = wait_for("id=fresh-after-skip ")
            assert "enter id=fresh-after-skip " in result and "skip id=fresh-after-skip " not in result, result
            assert "fixture: suppressed native key posting" in result, result
            print("PASS: skipped preparation does not prevent a later fresh completion from sending")
        finally:
            process.terminate()
            process.wait(timeout=5)
            connection.close()
