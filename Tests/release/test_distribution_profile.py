import copy
import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
import unittest
import platform
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("distribution_profile", ROOT / "Scripts/distribution-profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        self.profile = {
            "ProvisionsAllDevices": True, "Platform": ["OSX"],
            "TeamIdentifier": ["TEAM123456"],
            "ApplicationIdentifierPrefix": ["OLDPREFIX1"],
            "ExpirationDate": dt.datetime(2030, 1, 1),
            "DeveloperCertificates": [b"fixture-certificate"],
            "Entitlements": {
                module.APP_ID: "OLDPREFIX1.io.example.cliphoard",
                module.TEAM_ID: "TEAM123456",
                module.GROUPS: ["OLDPREFIX1.*"],
            },
        }
        self.template = {module.GROUPS: ["$(AppIdentifierPrefix)io.example.cliphoard"]}

    def prepare(self, profile=None):
        return module.prepare(self.profile if profile is None else profile, self.template,
                              "io.example.cliphoard", "TEAM123456", self.now)

    def test_prefix_is_from_profile_not_assumed_to_equal_team(self):
        claims = self.prepare()
        self.assertEqual(claims[module.GROUPS], ["OLDPREFIX1.io.example.cliphoard"])
        self.assertEqual(claims[module.APP_ID], "OLDPREFIX1.io.example.cliphoard")
        self.assertEqual(claims[module.TEAM_ID], "TEAM123456")

    def test_rejects_missing_expired_development_and_wrong_channel_profiles(self):
        cases = [
            ("ProvisionsAllDevices", False), ("ProvisionedDevices", ["device"]),
            ("Platform", ["iOS"]), ("TeamIdentifier", ["ANOTHER123"]),
            ("ExpirationDate", dt.datetime(2025, 12, 31)),
            ("DeveloperCertificates", []), ("ApplicationIdentifierPrefix", []),
        ]
        for key, value in cases:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile[key] = value
                with self.assertRaises(ValueError):
                    self.prepare(profile)

    def test_rejects_wrong_application_team_group_and_debug_entitlements(self):
        cases = [
            (module.APP_ID, "OLDPREFIX1.io.example.other"),
            (module.APP_ID, "OLDPREFIX1.*"),
            (module.TEAM_ID, "ANOTHER123"),
            (module.GROUPS, ["OLDPREFIX1.io.example.other"]),
            ("get-task-allow", True), ("com.apple.security.get-task-allow", True),
        ]
        for key, value in cases:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    self.prepare(profile)

    def test_only_trailing_profile_wildcards_are_allowed(self):
        self.assertTrue(module.allows("OLDPREFIX1.*", "OLDPREFIX1.io.example.cliphoard"))
        self.assertFalse(module.allows("OLDPREFIX1.*", "OTHER.io.example.cliphoard"))
        self.assertFalse(module.allows("OLD*.cliphoard", "OLDPREFIX1.io.example.cliphoard"))
        self.assertFalse(module.allows(["groupA"], ["groupA", "groupB"]))

    def test_new_or_unresolved_claims_fail_closed(self):
        for template in [{module.GROUPS: ["$(Unknown)foo"]},
                         {module.GROUPS: ["OLDPREFIX1.*"]},
                         {**self.template, "new-restricted-entitlement": True}]:
            with self.subTest(template=template):
                self.template = template
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_missing_embedded_profile_rejected_before_codesign(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(module, "run") as run:
            with self.assertRaisesRegex(ValueError, "missing provisioning profile"):
                module.verify(Path(directory), self.template, "TEAM123456")
            run.assert_not_called()

    def verify_fixture(self, leaf):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / "Contents").mkdir()
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "io.example.cliphoard"}))
            claims = self.prepare()

            def fake_run(*command):
                if "--entitlements" in command:
                    # Recent codesign defaults to an abstract [Dict]/[Key] view.
                    return plistlib.dumps(claims) if "--xml" in command else b"[Dict]\n"
                extraction = next((part for part in command
                                   if part.startswith("--extract-certificates=")), None)
                if extraction:
                    Path(extraction.split("=", 1)[1] + "0").write_bytes(leaf)
                return b""

            with patch.object(module, "decode", return_value=self.profile), \
                    patch.object(module, "run", side_effect=fake_run):
                module.verify(app, self.template, "TEAM123456")

    def test_signed_certificate_must_be_authorized_by_profile(self):
        with self.assertRaisesRegex(ValueError, "actual signing certificate"):
            self.verify_fixture(b"different-certificate")

    def test_authorized_signed_bundle_passes(self):
        self.verify_fixture(b"fixture-certificate")

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS codesign")
    def test_current_codesign_xml_output_is_readable(self):
        import plistlib
        data = module.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml",
                          "/System/Library/CoreServices/Finder.app")
        self.assertIsInstance(plistlib.loads(data), dict)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS codesign")
    def test_current_codesign_can_extract_real_certificate_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = str(Path(directory) / "certificate-")
            module.run("/usr/bin/codesign", "-d", "--extract-certificates=" + prefix,
                       "/System/Library/CoreServices/Finder.app")
            self.assertGreater(Path(prefix + "0").stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
