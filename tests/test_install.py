"""install.sh and uninstall.sh in a sandbox: fake HOME, with stub swiftc and launchctl first on PATH.
Nothing here touches the real service or the real LaunchAgents folder."""
import json
import glob
import os
import plistlib
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *  # noqa: E402,F403

SBX = f"{WORK}/sbx"
STUBS = f"{SBX}/stubs"
LABEL = "local.typeless-autosend"
UID = str(os.getuid())
CJK = re.compile("[" + chr(0x4E00) + "-" + chr(0x9FFF) + "]")  # any Chinese character
_homes = iter(range(10**6))

shutil.rmtree(SBX, ignore_errors=True)
os.makedirs(STUBS)
open(f"{STUBS}/swiftc", "w").write("""#!/bin/bash
if [ "$1" = "--version" ]; then [ "${SBX_NO_SWIFTC:-0}" = 1 ] && exit 1; echo "stub swiftc"; exit 0; fi
out=""; while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
printf '#!/bin/bash\\necho "stub binary $*"\\n' > "$out"; chmod +x "$out"
""")
open(f"{STUBS}/launchctl", "w").write("""#!/bin/bash
echo "$*" >> "$SBX_LOG"
case "$1" in
  bootstrap)
    if [ "${SBX_FAIL:-0}" = 1 ]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
    echo "[stub] started, accessibility trusted=false" >> "$SBX_APPDIR/autosend.log" ;;
  print) [ "${SBX_PRINT_OK:-0}" = 1 ] && exit 0 || exit 1 ;;
esac
exit 0
""")
for stub in ("swiftc", "launchctl"):
    os.chmod(f"{STUBS}/{stub}", 0o755)


def sandbox(sub):
    home = f"{SBX}/home-{next(_homes)}"
    d = f"{home}/{sub}"
    os.makedirs(d)
    for f in ("install.sh", "config.example.json", "uninstall.sh", *[os.path.basename(p) for p in glob.glob(f"{ROOT}/*.swift")]):
        shutil.copy(f"{ROOT}/{f}", d)
    return home, d


def run(script, home, d, *args, **extra):
    env = dict(os.environ, HOME=home, PATH=f"{STUBS}:/usr/bin:/bin", SHELL="/bin/zsh", SBX_LOG=f"{home}/launchctl.log", SBX_APPDIR=d)
    env.update(extra)
    return subprocess.run(["/bin/bash", script, *args], cwd=d, env=env, capture_output=True, text=True)


print("Normal install (directory with a space, two --app flags)")
home, d = sandbox("My Tools/typeless-autosend")
real = os.path.realpath(d)
open(f"{d}/.access-prompted", "w").close()
open(f"{d}/autosend.log", "w").write("old-log\n")
r = run("install.sh", home, d, "--app", "com.example.one", "--app", "com.example.two")
check("exits 0", r.returncode == 0, r.stderr[-200:])
check("config.json is created from --app", json.load(open(f"{d}/config.json")) == {"apps": ["com.example.one", "com.example.two"]})
plist_path = f"{home}/Library/LaunchAgents/{LABEL}.plist"
plist = plistlib.load(open(plist_path, "rb"))
check("plist points at the install directory, space included",
      plist["ProgramArguments"] == [f"{real}/typeless-autosend"] and plist["StandardOutPath"] == f"{real}/autosend.log")
check("plist label, KeepAlive and throttle",
      plist["Label"] == LABEL and plist["KeepAlive"] == {"SuccessfulExit": False} and plist["ThrottleInterval"] == 10)
calls = open(f"{home}/launchctl.log").read().splitlines()
check("both service names are stopped and checked before enable/bootstrap",
      calls == [f"bootout gui/{UID}/local.typeless-autoenter", f"print gui/{UID}/local.typeless-autoenter", f"bootout gui/{UID}/{LABEL}", f"print gui/{UID}/{LABEL}", f"enable gui/{UID}/{LABEL}", f"bootstrap gui/{UID} {plist_path}"], repr(calls))
check(".access-prompted is cleared so the next start prompts once", not os.path.exists(f"{d}/.access-prompted"))
check("the old log is kept as autosend.log.1 and the new log starts fresh",
      open(f"{d}/autosend.log.1").read() == "old-log\n" and "started," in open(f"{d}/autosend.log").read())
check("the binary is in place and nothing is left in .build",
      os.access(f"{d}/typeless-autosend", os.X_OK) and not os.path.exists(f"{d}/.build/typeless-autosend"))
check("output is English", "==> Building" in r.stdout and "Next steps:" in r.stdout and not CJK.search(r.stdout + r.stderr))
link_path = f"{home}/.local/bin/typeless-autosend"
check("installs globally callable link", os.path.islink(link_path) and os.path.realpath(link_path) == f"{real}/typeless-autosend")
profile = f"{home}/.zshrc"
profile_text = open(profile).read() if os.path.exists(profile) else ""
check("adds marked PATH setup for zsh", "# >>> typeless-autosend PATH >>>" in profile_text)
shell = subprocess.run(["/bin/zsh", "-c", 'source "$HOME/.zshrc"; command -v typeless-autosend'],
                       env=dict(os.environ, HOME=home, PATH="/usr/bin:/bin"), capture_output=True, text=True)
check("new shell can find global command", shell.returncode == 0 and shell.stdout.strip() == link_path)
again = run("install.sh", home, d, "--app", "com.example.three")
check("PATH setup is idempotent", os.path.exists(profile) and open(profile).read().count("# >>> typeless-autosend PATH >>>") == 1)
check("--app is ignored with a notice when config.json already exists",
      "left untouched" in again.stdout and json.load(open(f"{d}/config.json"))["apps"] == ["com.example.one", "com.example.two"])

uninstalled = run("uninstall.sh", home, d)
check("uninstall removes only its own global link", uninstalled.returncode == 0 and not os.path.lexists(link_path))
check("uninstall preserves config and harmless shared PATH setup", os.path.exists(f"{d}/config.json") and os.path.exists(profile))

print("Reinstall after moving the installed directory")
home, d = sandbox("old-location")
first = run("install.sh", home, d)
moved = f"{home}/new-location"
os.rename(d, moved)
relocated = run("install.sh", home, moved)
check("reinstall repairs owned stale command and service path", relocated.returncode == 0 and
      os.path.realpath(f"{home}/.local/bin/typeless-autosend") == f"{moved}/typeless-autosend",
      relocated.stderr[-200:])

print("Failure paths")
home, d = sandbox("ta")
r = run("install.sh", home, d, SBX_FAIL="1")
check("bootstrap failure: exit 1, the reason and the Login Items hint",
      r.returncode == 1 and "launchctl bootstrap failed: Bootstrap failed: 5: Input/output error" in r.stderr and "Login Items" in r.stderr)
home, d = sandbox("ta")
r = run("install.sh", home, d, SBX_NO_SWIFTC="1")
check("no compiler: exit 1 with a hint, nothing installed",
      r.returncode == 1 and "swiftc is not available" in r.stderr and not os.path.exists(f"{home}/Library/LaunchAgents"))
home, d = sandbox("ta")
r = run("install.sh", home, d, "--bogus")
check("unknown argument: exit 2", r.returncode == 2 and "Unknown argument" in r.stderr)
r = run("install.sh", home, d, "--app", "bad id")
check("invalid Bundle ID: exit 2", r.returncode == 2 and "Invalid Bundle ID" in r.stderr)
r = run("install.sh", home, d, "-h")
check("-h prints the three header lines", r.returncode == 0 and r.stdout.count("\n") == 3 and "Usage" in r.stdout)
home, d = sandbox("a&b/ta")
r = run("install.sh", home, d)
check("a path containing & is refused", r.returncode == 1 and "contains one of" in r.stderr)

print("Protected folders are refused, in any letter case")
for sub in ("Desktop/ta", "desktop/ta", "DOWNLOADS/ta", "Documents/x/y", "documents",
            "Library/Mobile Documents/com~apple~CloudDocs/ta", "library/cloudstorage/ta"):
    home, d = sandbox(sub)
    r = run("install.sh", home, d)
    check(sub, r.returncode == 1 and "protected location" in r.stderr and not os.path.exists(f"{d}/typeless-autosend")
          and not os.path.exists(f"{home}/launchctl.log"), f"(rc={r.returncode})")
home, d = sandbox("Developer/ta")
r = run("install.sh", home, d)
check("an ordinary directory is not refused", r.returncode == 0)

print("uninstall.sh")
home, d = sandbox("ta")
os.makedirs(f"{home}/Library/LaunchAgents")
plist_path = f"{home}/Library/LaunchAgents/{LABEL}.plist"
open(plist_path, "w").write("x")
r = run("uninstall.sh", home, d)
check("service stopped: plist removed, exit 0", r.returncode == 0 and not os.path.exists(plist_path) and "Stopped the service" in r.stdout)
open(plist_path, "w").write("x")
r = run("uninstall.sh", home, d, SBX_PRINT_OK="1")
check("service still running: plist kept, exit 1, manual command shown",
      r.returncode == 1 and os.path.exists(plist_path) and "Stop it manually" in r.stderr)
finish()
