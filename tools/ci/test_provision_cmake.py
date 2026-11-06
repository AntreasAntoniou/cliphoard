"""Changed CMake admission/output paths; no downloads or executable fixtures."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import provision_cmake as provisioner


class FakeRun:
    def __init__(self, root, version='cmake version 4.4.4'):
        self.root, self.version, self.calls = root, version, []

    def command(self, name, argv, seconds):
        self.calls.append((name, argv, seconds))
        result = self.root/(name + '.stdout')
        result.write_text(self.version + '\n' if name == 'version' else '')
        return result


class ProvisionTests(unittest.TestCase):
    def exercise(self, version='cmake version 4.4.4', failed_download=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            binary = root/'venv/lib/python3.14/site-packages/cmake/data/bin/cmake'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'non-executable fixture')
            run = FakeRun(root, version)
            def download(item, destination, runner):
                self.assertEqual(item['sha256'], '883962a72b1b3a16ff445427f24c8caca9797dd9e563bbe208cbcd89e877f9d3')
                if failed_download:
                    raise provisioner.bounded.Refused('download hash')
                destination.write_bytes(b'fixture')
            with patch.object(provisioner.bounded, 'download', side_effect=download), \
                 patch.object(provisioner.bounded, 'inspect_wheel', return_value=20), \
                 patch.object(provisioner.bounded, 'validate_records', return_value={'versions': {'cmake': '4.4.4'}}) as records:
                if failed_download or version != 'cmake version 4.4.4':
                    with self.assertRaises(provisioner.bounded.Refused):
                        provisioner.provision(run)
                    self.assertFalse((root/'PROVENANCE.json').exists())
                    if failed_download:
                        self.assertEqual(run.calls, [])
                        records.assert_not_called()
                else:
                    self.assertEqual(provisioner.provision(run), binary)
                    self.assertEqual(records.call_args.args[2], {'cmake': '4.4.4'})
                    self.assertIn('--without-pip', run.calls[0][1])
                    self.assertIn('--python', run.calls[1][1])
                    self.assertIn('--no-index', run.calls[1][1])
                    self.assertEqual(run.calls[2][1], [str(binary), '--version'])
                    self.assertEqual(json.loads((root/'PROVENANCE.json').read_text())['cmake']['path'], str(binary))

    def test_exact_tool_uses_native_binary_and_offline_target_install(self):
        self.exercise()

    def test_wrong_version_refused(self):
        self.exercise('cmake version 4.4.5')

    def test_bad_download_stops_before_install(self):
        self.exercise(failed_download=True)

    def test_cleanup_failure_does_not_publish_actions_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)/'outputs'
            class FailedCleanup:
                def __init__(self, *args): pass
                def __enter__(self): return self
                def __exit__(self, *args): raise provisioner.bounded.Refused('cleanup unconfirmed')
            with patch.object(provisioner.bounded, 'Runner', FailedCleanup), \
                 patch.object(provisioner, 'provision', return_value=Path(temporary)/'cmake'), \
                 patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}), \
                 patch('sys.argv', ['provision_cmake.py', '--work-dir', temporary]):
                with self.assertRaises(provisioner.bounded.Refused):
                    provisioner.main()
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
