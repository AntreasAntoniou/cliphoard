"""Hosted discovery tests using fixed synthetic tool output, no tool execution."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import admit_host as host


class HostTests(unittest.TestCase):
    def exercise(self, changed=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report, output = root/"host.json", root/"outputs"
            versions = {"cmake": "cmake version 4.4.4", "ninja": "1.13.2",
                        "sdk": "26.5", "xcode": "Xcode 26.6\nBuild version 17F113",
                        "clang": "Apple clang version 21.0.0 (clang-2100.4.1.1)",
                        "native": json.dumps([[3,13,13],"arm64",str(root)])}
            if changed:
                versions[changed] = "unsupported"

            def run(command, _environment):
                if "--find" in command:
                    return sys.executable if changed == "outside" else str(root/command[-1])
                if "--show-sdk-path" in command: return str(root/"SDK")
                if "--show-sdk-version" in command: return versions["sdk"]
                if command[0] == "/usr/bin/xcodebuild": return versions["xcode"]
                if "-c" in command: return versions["native"]
                return versions[Path(command[0]).name]

            for name in ("cmake", "ninja"):
                (root/name).touch()
            (root/"clang").touch()
            (root/"clang++").touch()
            (root/"SDK").mkdir()
            env = {"DEVELOPER_DIR": str(root), "GITHUB_OUTPUT": str(output), "HOME": "/unchanged"}
            with patch.object(host, "DEVELOPER", str(root)), patch.object(host, "checked", side_effect=run), \
                 patch.object(host.shutil, "which", side_effect=lambda n, path: str(root/n)), \
                 patch.object(host.platform, "system", return_value="Darwin"), \
                 patch.object(host.platform, "machine", return_value="arm64"), \
                 patch.dict(os.environ, env), patch.object(sys, "argv", ["admit_host.py", "--python313", sys.executable, "--cmake", str(root/"cmake"), "--report", str(report)]):
                if changed:
                    with self.assertRaises((ValueError, json.JSONDecodeError)):
                        host.main()
                    self.assertFalse(report.exists())
                    self.assertFalse(output.exists())
                else:
                    host.main()
                    saved = json.loads(report.read_text())
                    self.assertEqual(saved["versions"]["sdk"], "26.5")
                    self.assertEqual(saved["python313"]["version"], [3,13,13])
                    self.assertEqual(len(output.read_text().splitlines()), 5)

    def test_expected_tools(self):
        self.exercise()

    def test_drift_stops_before_receipt_and_action_outputs(self):
        for changed in ("cmake", "ninja", "sdk", "xcode", "clang", "native", "outside"):
            with self.subTest(changed=changed):
                self.exercise(changed)


if __name__ == "__main__":
    unittest.main()
