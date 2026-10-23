import datetime as dt
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_mas_profile", ROOT / "Scripts" / "verify-mas-profile.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyMASProfileTests(unittest.TestCase):
    def setUp(self):
        self.team = "74M96PGT6P"
        self.prefix = "APPREFIX123"
        self.bundle = "ai.a2-labs.cliphoard"
        self.cert = b"mac-app-distribution-leaf"
        self.intended = {
            MODULE.SANDBOX: True,
            MODULE.USER_SELECTED_RW: True,
            MODULE.APP_ID: self.prefix + "." + self.bundle,
            MODULE.TEAM_ID: self.team,
            MODULE.GROUPS: [self.prefix + "." + self.bundle],
        }
        self.profile = {
            "Platform": ["OSX"],
            "ExpirationDate": dt.datetime(2030, 1, 1, tzinfo=dt.timezone.utc),
            "TeamIdentifier": [self.team],
            "ApplicationIdentifierPrefix": [self.prefix],
            "DeveloperCertificates": [self.cert],
            "Entitlements": {
                "get-task-allow": False,
                MODULE.APP_ID: self.prefix + "." + self.bundle,
                MODULE.TEAM_ID: self.team,
                MODULE.GROUPS: [self.prefix + ".*"],
            },
        }

    def verify(self):
        return MODULE.verify_profile(
            self.profile, self.intended, self.bundle, self.team,
            now=dt.datetime(2029, 1, 1, tzinfo=dt.timezone.utc))

    def test_valid_store_profile_and_exact_signed_claims(self):
        self.assertEqual(self.verify(), self.prefix)
        MODULE.verify_signed(self.profile, self.intended, dict(self.intended), self.cert)

    def test_profile_does_not_need_to_claim_ordinary_powerbox_entitlement(self):
        self.assertNotIn(MODULE.USER_SELECTED_RW, self.profile["Entitlements"])
        self.assertEqual(self.verify(), self.prefix)

    def test_macos_profile_may_omit_debugger_entitlements(self):
        # A profile issued by Apple's Mac App Store portal has neither key.
        self.profile["Entitlements"].pop("get-task-allow")
        self.assertEqual(self.verify(), self.prefix)

    def test_debugger_entitlements_may_be_explicitly_false(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            with self.subTest(key=key):
                self.profile["Entitlements"][key] = False
                self.intended[key] = False
                self.assertEqual(self.verify(), self.prefix)
                MODULE.verify_signed(self.profile, self.intended,
                                     dict(self.intended), self.cert)

    def test_profile_rejects_enabled_or_malformed_debugger_entitlements(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            for value in (True, 0, 1, "false", None, [], {}):
                with self.subTest(key=key, value=value):
                    self.setUp()
                    self.profile["Entitlements"][key] = value
                    with self.assertRaisesRegex(ValueError, "debugger access"):
                        self.verify()

    def test_intended_rejects_enabled_or_malformed_debugger_entitlements(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            for value in (True, 0, 1, "false", None, [], {}):
                with self.subTest(key=key, value=value):
                    self.setUp()
                    self.intended[key] = value
                    with self.assertRaisesRegex(ValueError, "debugger access"):
                        self.verify()

    def test_signed_matching_debugger_claims_are_still_rejected(self):
        # Exact signed/intended equality must not authorize debugging by itself.
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            for value in (True, 0, 1, "false", None, [], {}):
                with self.subTest(key=key, value=value):
                    self.setUp()
                    self.intended[key] = value
                    with self.assertRaisesRegex(ValueError, "debugger access"):
                        MODULE.verify_signed(self.profile, self.intended,
                                             dict(self.intended), self.cert)

    def test_signed_debugger_claim_cannot_be_added_after_preflight(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            with self.subTest(key=key):
                actual = dict(self.intended)
                actual[key] = True
                with self.assertRaisesRegex(ValueError, "debugger access"):
                    MODULE.verify_signed(self.profile, self.intended, actual, self.cert)

    def test_rejects_expired_non_macos_and_non_distribution_profiles(self):
        cases = [
            ("ExpirationDate", dt.datetime(2028, 1, 1, tzinfo=dt.timezone.utc)),
            ("Platform", ["iOS"]),
            ("ProvisionedDevices", ["device-id"]),
            ("ProvisionsAllDevices", True),
        ]
        for key, value in cases:
            with self.subTest(key=key):
                original = self.profile.get(key)
                self.profile[key] = value
                with self.assertRaises(ValueError):
                    self.verify()
                if original is None:
                    self.profile.pop(key)
                else:
                    self.profile[key] = original

    def test_rejects_debug_wrong_team_prefix_or_app_id(self):
        mutations = [
            lambda: self.profile["Entitlements"].__setitem__("get-task-allow", True),
            lambda: self.profile.__setitem__("TeamIdentifier", ["OTHERTEAM"]),
            lambda: self.profile.__setitem__("ApplicationIdentifierPrefix", ["OTHERPREFIX"]),
            lambda: self.profile["Entitlements"].__setitem__(
                MODULE.APP_ID, self.prefix + ".wrong.bundle"),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                profile = {**self.profile, "Entitlements": dict(self.profile["Entitlements"])}
                self.profile = profile
                mutate()
                with self.assertRaises(ValueError):
                    self.verify()
                self.setUp()

    def test_rejects_unauthorized_keychain_group(self):
        self.intended[MODULE.GROUPS] = [self.prefix + ".another-app"]
        self.profile["Entitlements"][MODULE.GROUPS] = [self.prefix + "." + self.bundle]
        with self.assertRaisesRegex(ValueError, "keychain-access-groups"):
            self.verify()

    def test_exact_post_sign_comparison_rejects_missing_or_extra_entitlement(self):
        missing = dict(self.intended)
        missing.pop(MODULE.USER_SELECTED_RW)
        with self.assertRaisesRegex(ValueError, "exactly match"):
            MODULE.verify_signed(self.profile, self.intended, missing, self.cert)
        extra = dict(self.intended)
        extra["com.apple.security.network.client"] = True
        with self.assertRaisesRegex(ValueError, "exactly match"):
            MODULE.verify_signed(self.profile, self.intended, extra, self.cert)

    def test_rejects_leaf_not_in_profile_allowlist(self):
        with self.assertRaisesRegex(ValueError, "DeveloperCertificates"):
            MODULE.verify_signed(self.profile, self.intended, self.intended, b"other-cert")

    def test_codesign_certificate_optional_argument_uses_equals_form(self):
        args = MODULE.certificate_extraction_args(Path("Cliphoard.app"), Path("cert-"))
        self.assertIn("--extract-certificates=cert-", args)
        self.assertNotIn("--extract-certificates", args)


if __name__ == "__main__":
    unittest.main()
