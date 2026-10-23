#!/usr/bin/env python3
"""Verify a Mac App Store profile and the app signed with it.

This deliberately treats ordinary App Sandbox entitlements separately from the claims
controlled by a provisioning profile. It never creates profiles, identities, or portal state.
"""
import argparse
import datetime as dt
import hashlib
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
GROUPS = "keychain-access-groups"
SANDBOX = "com.apple.security.app-sandbox"
USER_SELECTED_RW = "com.apple.security.files.user-selected.read-write"
DEBUGGER_ENTITLEMENTS = ("get-task-allow", "com.apple.security.get-task-allow")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def reject_debugger_access(entitlements, source):
    # TN3125: macOS's com.apple.security.get-task-allow is unrestricted; unlike
    # iOS's get-task-allow, it need not appear in a Mac distribution profile.
    # Absence grants no debugger access. Present values must be Boolean false,
    # including on the intended and actual app signature, not just the profile.
    for key in DEBUGGER_ENTITLEMENTS:
        if key in entitlements:
            require(entitlements[key] is False,
                    source + " must not authorize debugger access: " + key)


def allows(allowed, claimed):
    """Provisioning profile wildcards are a single trailing star."""
    if isinstance(claimed, list):
        return isinstance(allowed, list) and all(
            any(allows(entry, value) for entry in allowed) for value in claimed
        )
    if isinstance(allowed, str) and isinstance(claimed, str):
        return allowed == claimed or (
            allowed.endswith("*") and "*" not in allowed[:-1]
            and claimed.startswith(allowed[:-1])
        )
    return type(allowed) is type(claimed) and allowed == claimed


def verify_profile(profile, intended, bundle_id, team_id, now=None):
    require("OSX" in profile.get("Platform", []), "profile must target macOS")
    require(not profile.get("ProvisionedDevices"),
            "device-limited development/ad hoc profiles are not App Store profiles")
    require(profile.get("ProvisionsAllDevices") is not True,
            "Developer ID profiles are not App Store profiles")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime), "profile has no expiration date")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    require(expiry > (now or dt.datetime.now(dt.timezone.utc)), "profile has expired")
    require(team_id in profile.get("TeamIdentifier", []), "profile belongs to another team")

    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(isinstance(prefixes, list) and len(prefixes) == 1
            and isinstance(prefixes[0], str) and prefixes[0],
            "profile needs one unambiguous App ID prefix")
    prefix = prefixes[0]
    permitted = profile.get("Entitlements", {})
    require(isinstance(permitted, dict), "profile entitlements are invalid")
    reject_debugger_access(permitted, "profile")
    reject_debugger_access(intended, "intended entitlements")

    require(intended.get(SANDBOX) is True, "intended entitlements must enable App Sandbox")
    require(intended.get(USER_SELECTED_RW) is True,
            "intended entitlements must preserve user-selected read/write access")
    expected_app_id = prefix + "." + bundle_id
    require(intended.get(APP_ID) == expected_app_id,
            "intended application identifier does not match profile prefix and bundle ID")
    require(intended.get(TEAM_ID) == team_id, "intended team identifier is wrong")

    # These are profile-controlled claims. Ordinary sandbox entitlements such as the
    # user-selected file grant are verified exactly after signing but are not required to
    # appear in the provisioning profile.
    for key in (APP_ID, TEAM_ID, GROUPS):
        require(key in intended, "intended entitlements are missing " + key)
        require(key in permitted and allows(permitted[key], intended[key]),
                "profile does not authorize entitlement: " + key)

    certificates = profile.get("DeveloperCertificates", [])
    require(isinstance(certificates, list) and certificates
            and all(isinstance(cert, bytes) and cert for cert in certificates),
            "profile has no authorized distribution certificates")
    return prefix


def verify_signed(profile, intended, actual, leaf_certificate):
    reject_debugger_access(intended, "intended entitlements")
    reject_debugger_access(actual, "signed entitlements")
    require(actual == intended,
            "signed entitlements do not exactly match the intended expanded template")
    allowed = profile.get("DeveloperCertificates", [])
    require(any(hashlib.sha256(cert).digest() == hashlib.sha256(leaf_certificate).digest()
                for cert in allowed),
            "actual signing certificate is not in profile DeveloperCertificates")


def run(command):
    result = subprocess.run(command, capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError(command[0] + " failed: "
                         + result.stderr.decode(errors="replace").strip())
    return result.stdout


def certificate_extraction_args(app, prefix):
    # codesign's optional argument belongs in the same argv element. A separated prefix is
    # parsed as another input path on some macOS versions.
    return ["/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), str(app)]


def read_signed_app(app):
    actual = plistlib.loads(run([
        "/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)
    ]))
    run(["/usr/bin/codesign", "--verify", "--strict", str(app)])
    with tempfile.TemporaryDirectory(prefix="cliphoard-mas-profile-") as directory:
        prefix = Path(directory) / "cert-"
        run(certificate_extraction_args(app, prefix))
        leaf = Path(str(prefix) + "0").read_bytes()
    return actual, leaf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("profile", "signed"))
    parser.add_argument("--profile-plist", type=Path, required=True)
    parser.add_argument("--intended-entitlements", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        profile = plistlib.loads(args.profile_plist.read_bytes())
        intended = plistlib.loads(args.intended_entitlements.read_bytes())
        prefix = verify_profile(profile, intended, args.bundle_id, args.team_id)
        if args.mode == "signed":
            require(args.app is not None and args.app.is_dir(), "signed mode requires --app")
            actual, leaf = read_signed_app(args.app)
            verify_signed(profile, intended, actual, leaf)
        print("Mac App Store profile " + args.mode + " verification: passed (prefix "
              + prefix + ")")
    except (ValueError, OSError, KeyError, TypeError, plistlib.InvalidFileException,
            subprocess.TimeoutExpired) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
