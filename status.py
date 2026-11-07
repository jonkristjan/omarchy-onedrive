#!/usr/bin/env python3
"""One JSON snapshot of the OneDrive client (abraunegg/onedrive) for the bar widget.

Reads only local state, never the network:
  - systemd:  `systemctl --user show onedrive.service`
  - client:   ~/.config/onedrive/monitor-status.json (written by `onedrive --monitor`)
  - journal:  recent uploads, downloads, deletes and failed items
  - sync_list and the sync folder, for what is synced and how much

Usage: status.py [--light]   (--light skips the journal and the folder walk)
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

UNIT = "onedrive.service"
CONFIG_DIR = os.path.expanduser("~/.config/onedrive")
STATUS_FILE = os.path.join(CONFIG_DIR, "monitor-status.json")
SYNC_LIST = os.path.join(CONFIG_DIR, "sync_list")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config")

# Only plain URL characters: omarchy-launch-or-focus passes the launch command
# through `eval`, so a URL with shell metacharacters (& ; $ ` ( ) ...) is refused.
WEB_APP_DIRS = [os.path.expanduser("~/.local/share/applications")]
WEB_APP_URL = re.compile(r'omarchy-launch-webapp\s+"?(https://(?:onedrive\.live\.com|onedrive\.com|(?:www\.)?office\.com/launch/onedrive|[A-Za-z0-9-]+-my\.sharepoint\.com)[A-Za-z0-9._~/?=%:+-]*)"?(?:\s|$)')
MAX_ACTIVITY = 25
MAX_FAILURES = 10
MAX_PATH = 300
JOURNAL_DAYS = 30
TRANSFER_WINDOW_SEC = 90

ACTIVITY_PATTERNS = [
    (re.compile(r"^Uploading new file: (.+?) \.\.\. (done|failed!?)\s*$"), "upload"),
    (re.compile(r"^Uploading modified file: (.+?) \.\.\. (done|failed!?)\s*$"), "upload"),
    (re.compile(r"^Downloading file: (.+?) \.\.\. (done|failed!?)\s*$"), "download"),
    (re.compile(r"^Deleting item from Microsoft OneDrive: (.+)$"), "delete"),
    (re.compile(r"^Trying to delete this item: (.+)$"), "delete"),
]
FAILED_PATTERN = re.compile(r"^Failed to (download|upload): (.+)$")


def run(argv, timeout=5):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return out.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def clean_path(path):
    path = str(path).strip()
    if path.startswith("./"):
        path = path[2:]
    return path[:MAX_PATH]


def iso_to_unix(value):
    if not value or not isinstance(value, str):
        return 0
    # The client writes 7 fractional digits; Python wants at most 6.
    value = re.sub(r"(\.\d{6})\d+", r"\1", value).replace("Z", "+00:00")
    try:
        return int(datetime.fromisoformat(value).timestamp())
    except ValueError:
        return 0


def service_state():
    props = {}
    for line in run(["systemctl", "--user", "show", UNIT, "--timestamp=unix", "-p",
                     "ActiveState,SubState,ActiveEnterTimestamp,MemoryCurrent,MemoryHigh,MainPID,NRestarts"]).splitlines():
        key, _, value = line.partition("=")
        props[key] = value

    def num(key):
        try:
            n = int(props.get(key, ""))
            return n if n < 2**63 else 0  # "infinity" comes back as UINT64_MAX
        except ValueError:
            return 0

    since = props.get("ActiveEnterTimestamp", "").lstrip("@")
    return {
        "active": props.get("ActiveState", "unknown"),
        "sub": props.get("SubState", ""),
        "since": int(since) if since.isdigit() else 0,
        "memoryBytes": num("MemoryCurrent"),
        "memoryHigh": num("MemoryHigh"),
        "pid": num("MainPID"),
        "restarts": num("NRestarts"),
    }


def client_state():
    try:
        with open(STATUS_FILE, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    process = raw.get("process") or {}
    sync = raw.get("sync") or {}
    cycle = sync.get("last_cycle") or {}
    conditions = raw.get("conditions") or {}
    mode = raw.get("mode") or {}

    def count(v):
        return v if isinstance(v, int) and v >= 0 else 0

    return {
        "pid": count(raw.get("pid")),
        "state": str(process.get("state", ""))[:32],
        "reachability": str(conditions.get("onedrive_reachability", ""))[:32],
        "cycleStartedAt": iso_to_unix(process.get("current_cycle_started_at")),
        "lastSuccessAt": iso_to_unix(sync.get("last_successful_sync_at")),
        "successfulCycles": count(sync.get("successful_cycle_count")),
        "intervalSec": count(mode.get("monitor_interval_seconds")),
        "updatedAt": iso_to_unix(raw.get("updated_at")),
        "lastCycle": {
            "result": str(cycle.get("result", ""))[:32],
            "startedAt": iso_to_unix(cycle.get("started_at")),
            "completedAt": iso_to_unix(cycle.get("completed_at")),
            "durationSec": count(cycle.get("duration_seconds")),
            "uploadFailures": count(cycle.get("upload_failures")),
            "downloadFailures": count(cycle.get("download_failures")),
        },
    }


def journal(cycle=None, window=f"-{JOURNAL_DAYS}d", limit=20000):
    """Recent file activity, newest first, plus the items that failed during
    the last completed cycle (none when no cycle has completed yet)."""
    start = cycle["startedAt"] if cycle else 0
    end = cycle["completedAt"] if cycle else 0
    out = run(["journalctl", "--user", "-u", UNIT, "-o", "json", "--no-pager",
               "--since", window, "-n", str(limit), "--output-fields=MESSAGE"], timeout=10)
    activity, failures = [], {}
    for line in out.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        msg = entry.get("MESSAGE")
        if not isinstance(msg, str):
            continue  # binary or missing
        try:
            ts = int(entry.get("__REALTIME_TIMESTAMP", "0")) // 1_000_000
        except ValueError:
            ts = 0
        failed = FAILED_PATTERN.match(msg)
        if failed:
            if start and end and start <= ts <= end:
                failures[clean_path(failed.group(2))] = {"path": clean_path(failed.group(2)),
                                                         "direction": failed.group(1), "ts": ts}
            continue
        for pattern, kind in ACTIVITY_PATTERNS:
            m = pattern.match(msg)
            if m:
                ok = len(m.groups()) < 2 or m.group(2) == "done"
                activity.append({"kind": kind, "path": clean_path(m.group(1)), "ts": ts, "ok": ok})
                break
    activity.reverse()
    return activity[:MAX_ACTIVITY], sorted(failures.values(), key=lambda f: -f["ts"])[:MAX_FAILURES]


def sync_dir():
    path = "~/OneDrive"
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            for line in f:
                m = re.match(r'^\s*sync_dir\s*=\s*"([^"]*)"', line)
                if m:
                    path = m.group(1)
    except OSError:
        pass
    return os.path.expanduser(path)


def synced_folders():
    folders = []
    try:
        with open(SYNC_LIST, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith(("#", ";", "!", "-")):
                    continue
                folders.append(line.strip("/"))
    except OSError:
        pass
    return folders[:50]


def onedrive_web_app():
    """URL of an Omarchy web app for OneDrive (made with omarchy-webapp-install), if any."""
    for directory in WEB_APP_DIRS:
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            if not name.endswith(".desktop"):
                continue
            try:
                with open(os.path.join(directory, name), encoding="utf-8") as f:
                    for line in f:
                        if line.startswith("Exec="):
                            m = WEB_APP_URL.search(line)
                            if m and len(m.group(1)) <= 300:
                                return m.group(1)
                            break
            except (OSError, UnicodeDecodeError):
                continue
    return ""


def folder_usage(root, rel):
    files = size = 0
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, rel)):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            try:
                st = os.lstat(os.path.join(dirpath, name))
            except OSError:
                continue
            files += 1
            size += st.st_size
    return files, size


def overall(service, client, transferring):
    """One state for the bar: stopped, failed, starting, offline, warning, transferring, checking, ok.

    The client's state is "syncing" for most of every cycle (a cycle can take
    nearly the whole monitor interval), so that alone is "checking"; only files
    actually moving in the last TRANSFER_WINDOW_SEC count as "transferring".
    """
    if service["active"] in ("inactive", "deactivating"):
        return "stopped"
    if service["active"] == "failed":
        return "failed"
    if service["active"] == "activating":
        return "starting"
    # A status file from an earlier process says nothing about this one.
    if not client or (service["pid"] and client["pid"] and client["pid"] != service["pid"]):
        return "starting"
    if client["reachability"] and client["reachability"] != "reachable":
        return "offline"
    last = client["lastCycle"]
    # "never_run" right after a start is not a problem; only failed items or a
    # result that says so are.
    if last["uploadFailures"] or last["downloadFailures"] or re.search(r"fail|error", last["result"], re.I):
        return "warning"
    if transferring:
        return "transferring"
    if client["state"] == "syncing":
        return "checking"
    if not client["lastSuccessAt"]:
        return "starting"
    return "ok"


def main():
    light = "--light" in sys.argv[1:]
    service = service_state()
    client = client_state()
    recent, _ = journal(None, window=f"-{TRANSFER_WINDOW_SEC}s", limit=200) if service["active"] == "active" else ([], [])
    result = {
        "ok": True,
        "now": int(time.time()),
        "status": overall(service, client, any(a["kind"] in ("upload", "download") for a in recent)),
        "service": service,
        "client": client,
        "syncDir": sync_dir(),
    }
    if not light:
        result["activity"], result["failures"] = journal(client["lastCycle"] if client else None)
        root = result["syncDir"]
        folders = []
        for rel in synced_folders():
            files, size = folder_usage(root, rel)
            folders.append({"path": rel, "files": files, "bytes": size})
        result["folders"] = folders
        result["webAppUrl"] = onedrive_web_app()
        result["totals"] = {"files": sum(f["files"] for f in folders),
                            "bytes": sum(f["bytes"] for f in folders)}
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
