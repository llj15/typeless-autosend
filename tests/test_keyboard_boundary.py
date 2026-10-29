"""Exercise production InputMonitor registration and handling at the CG boundary.

The injected library replaces OS taps with local ports, and routes in-memory
CGEvents only. It never registers a real tap or posts keyboard input.
"""
import os
from pathlib import Path
import subprocess
from common import ROOT, WORK

source = Path(__file__).parent / "keyboard_boundary"
work = Path(WORK) / "keyboard-boundary"
work.mkdir(parents=True, exist_ok=True)
library = work / "libKeyboardBoundary.dylib"
binary = work / "keyboard-boundary"
subprocess.run([
    "clang", "-dynamiclib", str(source / "coregraphics.m"), "-o", str(library),
    "-framework", "ApplicationServices", "-framework", "Carbon", "-framework", "AppKit",
], check=True)
subprocess.run([
    "swiftc", *(str(path) for path in sorted(Path(ROOT).glob("*.swift")) if path.name != "main.swift"),
    str(source / "main.swift"), "-L", str(work), "-lKeyboardBoundary",
    "-Xlinker", "-rpath", "-Xlinker", str(work), "-o", str(binary), "-lsqlite3",
], check=True)
for scenario in ("fn", "consumer-after-daemon", "custom", "session", "hid-create-failure", "hid-timeout", "hid-invalid", "session-timeout", "session-invalid", "consumer-after-arm", "enumeration-failure"):
    result = subprocess.run([str(binary), scenario], env=dict(os.environ, DYLD_INSERT_LIBRARIES=str(library)))
    if result.returncode:
        raise SystemExit(result.returncode)
