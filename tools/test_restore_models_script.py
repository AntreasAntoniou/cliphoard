"""Run restore-models.sh against disposable complete caches; downloads/conversion are denied."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class RestoreModelsScriptTests(unittest.TestCase):
    def exercise_cached_restore(self, selection=None):
        self.assertGreaterEqual(sys.version_info[:2], (3, 14))
        script = Path(__file__).with_name("restore-models.sh")
        with tempfile.TemporaryDirectory(prefix="restore-models-script-") as temporary:
            root = Path(temporary)
            tools = root / "tools"
            tools.mkdir()
            shutil.copyfile(script, tools / "restore-models.sh")
            models = tools / "models"
            models.mkdir()
            names = ("open-ogma-micro", "open-ogma-small", "all-MiniLM-L6-v2",
                     "openvision-tiny-p8-image", "openvision-tiny-p8-text")
            for name in names:
                (models / (name + ".mlpackage")).mkdir()
                if name != "openvision-tiny-p8-image":
                    (models / name).mkdir()
                    (models / name / "tokenizer.json").write_text("{}")
            (models / "openvision-tiny-p8-text/config.json").write_text("{}")
            (models / "openvision-tiny-p8.zip.sha256").write_text(
                "c137d2f76e9ed583488cf5e5955f11d173192c05ccae4daa922e8ab6fdfb772a\n")
            bin_directory = root / "bin"
            bin_directory.mkdir()
            calls = root / "runtime-calls.jsonl"
            interpreter = bin_directory / "verified-runtime"
            interpreter.write_text(f"#!{sys.executable}\n" + f'''
import json, subprocess, sys
with open({str(calls)!r}, "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
expected = ['-c', 'import sys; assert sys.version_info >= (3, 13), "CoreML conversion requires Python 3.13+"']
if sys.argv[1:] != expected:
    raise SystemExit("Conversion/download execution forbidden in cached-script regression")
raise SystemExit(subprocess.run([{sys.executable!r}, *sys.argv[1:]], check=False).returncode)
''')
            interpreter.chmod(0o700)
            network_called = root / "network-called"
            for name in ("curl", "wget", "git", "ditto"):
                stub = bin_directory / name
                stub.write_text(f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(network_called)!r}).touch()\nraise SystemExit(91)\n")
                stub.chmod(0o700)
            environment = {"PATH": str(bin_directory) + ":/usr/bin:/bin", "LC_ALL": "C",
                           "CLIPHOARD_MODEL_PYTHON": str(interpreter)}
            if selection is not None:
                environment["MODELS"] = selection
            result = subprocess.run(["/bin/bash", str(tools / "restore-models.sh")], cwd=root,
                                    env=environment, text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected_names = selection.split() if selection is not None else names
            self.assertEqual(result.stdout.count("already present"), len(expected_names))
            self.assertIn("Models restored under", result.stdout)
            self.assertNotIn("Restoring ", result.stdout)
            self.assertNotIn("Downloading ", result.stdout)
            self.assertFalse(network_called.exists(), "No network tool may run")
            runtime_calls = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len(runtime_calls), 1, "Only the explicit runtime-version check may execute")
            self.assertEqual({path.name for path in models.glob("*.mlpackage")},
                             {name + ".mlpackage" for name in names})

    def test_default_cached_models_reach_completion_without_downloads(self):
        self.exercise_cached_restore()

    def test_explicit_cached_subset_reaches_completion_without_conversion(self):
        self.exercise_cached_restore("open-ogma-micro")


if __name__ == "__main__":
    unittest.main()
