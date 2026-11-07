"""Tests for status.py: journal parsing, the overall state, and web app detection.

Run: python3 -m unittest discover -s tests
"""

import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("status", os.path.join(HERE, "..", "status.py"))
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


def journal_lines(*entries):
    return "\n".join(json.dumps({"MESSAGE": msg, "__REALTIME_TIMESTAMP": str(ts * 1_000_000)})
                     for ts, msg in entries)


def client(**over):
    c = {"pid": 10, "state": "idle", "reachability": "reachable", "lastSuccessAt": 100,
         "lastCycle": {"result": "success", "startedAt": 50, "completedAt": 90,
                       "durationSec": 40, "uploadFailures": 0, "downloadFailures": 0}}
    c.update(over)
    return c


SERVICE = {"active": "active", "pid": 10}


class JournalTest(unittest.TestCase):
    def setUp(self):
        self._run = status.run

    def tearDown(self):
        status.run = self._run

    def parse(self, text, cycle=None):
        status.run = lambda argv, timeout=5: text
        return status.journal(cycle)

    def test_transfers_newest_first_with_dot_slash_removed(self):
        activity, _ = self.parse(journal_lines(
            (1, "Uploading new file: ./Documents/a.xlsx ... done"),
            (2, "Downloading file: Work/b.docx ... failed!"),
            (3, "Deleting item from Microsoft OneDrive: ./Old/c.txt"),
            (4, "Uploading: Documents/a.xlsx ... 100% | DONE in 00:00"),  # progress line, ignored
        ))
        self.assertEqual([(a["kind"], a["path"], a["ok"]) for a in activity], [
            ("delete", "Old/c.txt", True),
            ("download", "Work/b.docx", False),
            ("upload", "Documents/a.xlsx", True),
        ])

    def test_failures_only_inside_the_last_completed_cycle(self):
        text = journal_lines((10, "Failed to download: old.xlsx"), (60, "Failed to upload: new.docx"))
        _, failures = self.parse(text, {"startedAt": 50, "completedAt": 90})
        self.assertEqual([f["path"] for f in failures], ["new.docx"])
        _, failures = self.parse(text, {"startedAt": 0, "completedAt": 0})  # never_run
        self.assertEqual(failures, [])

    def test_markup_shaped_names_pass_through_as_data(self):
        activity, _ = self.parse(journal_lines((1, 'Downloading file: <img src="https://x.invalid/t">.docx ... done')))
        self.assertEqual(activity[0]["path"], '<img src="https://x.invalid/t">.docx')


class OverallTest(unittest.TestCase):
    def test_states(self):
        o = status.overall
        self.assertEqual(o({"active": "inactive", "pid": 0}, None, False), "stopped")
        self.assertEqual(o({"active": "failed", "pid": 0}, None, False), "failed")
        self.assertEqual(o(SERVICE, None, False), "starting")
        self.assertEqual(o(SERVICE, client(pid=9), False), "starting")  # file from an earlier process
        self.assertEqual(o(SERVICE, client(reachability="unreachable"), False), "offline")
        self.assertEqual(o(SERVICE, client(state="syncing"), False), "checking")
        self.assertEqual(o(SERVICE, client(state="syncing"), True), "transferring")
        self.assertEqual(o(SERVICE, client(), False), "ok")

    def test_never_run_after_a_start_is_not_a_warning(self):
        c = client(state="syncing", lastSuccessAt=0)
        c["lastCycle"] = dict(c["lastCycle"], result="never_run")
        self.assertEqual(status.overall(SERVICE, c, False), "checking")

    def test_failed_items_are_a_warning(self):
        c = client()
        c["lastCycle"] = dict(c["lastCycle"], downloadFailures=2)
        self.assertEqual(status.overall(SERVICE, c, False), "warning")


class WebAppTest(unittest.TestCase):
    def find(self, exec_line):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "OneDrive.desktop"), "w") as f:
                f.write("[Desktop Entry]\nName=OneDrive\n" + exec_line + "\n")
            old = status.WEB_APP_DIRS
            status.WEB_APP_DIRS = [d]
            try:
                return status.onedrive_web_app()
            finally:
                status.WEB_APP_DIRS = old

    def test_finds_onedrive_web_apps(self):
        self.assertEqual(self.find('Exec=omarchy-launch-webapp "https://www.office.com/launch/onedrive"'),
                         "https://www.office.com/launch/onedrive")
        self.assertEqual(self.find("Exec=omarchy-launch-webapp https://onedrive.live.com/"),
                         "https://onedrive.live.com/")

    def test_refuses_shell_metacharacters_and_other_sites(self):
        # omarchy-launch-or-focus evals its launch command.
        self.assertEqual(self.find('Exec=omarchy-launch-webapp "https://onedrive.live.com/?a=1&b=$(id)"'), "")
        self.assertEqual(self.find("Exec=omarchy-launch-webapp https://onedrive.live.com/;id"), "")
        self.assertEqual(self.find('Exec=omarchy-launch-webapp "https://evil.example/onedrive"'), "")


if __name__ == "__main__":
    unittest.main()
