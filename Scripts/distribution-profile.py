#!/usr/bin/env python3
"""Prepare and check Cliphoard's Developer ID provisioning, without signing it.

Notarization and codesign --verify do not authorize restricted entitlements.
macOS also checks the embedded profile at process launch (Apple TN3125).
This is a packaging preflight, not a replacement for a clean-machine launch test.
"""
import argparse
import datetime as dt
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
GROUPS = "keychain-access-groups"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def allows(allowed, claimed):
    """Apple profile wildcards are trailing '*', not shell glob patterns."""
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


def prepare(profile, template, bundle_id, team_id, now=None):
    require(profile.get("ProvisionsAllDevices") is True,
            "use a Developer ID distribution profile (ProvisionsAllDevices is required)")
    require(not profile.get("ProvisionedDevices"), "device-limited profiles are not distributable")
    require("OSX" in profile.get("Platform", []), "profile must target macOS")
    require(team_id in profile.get("TeamIdentifier", []), "profile belongs to another team")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime), "profile has no expiration date")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    require(expiry > (now or dt.datetime.now(dt.timezone.utc)), "provisioning profile has expired")
    certificates = profile.get("DeveloperCertificates", [])
    require(isinstance(certificates, list) and certificates
            and all(isinstance(cert, bytes) and cert for cert in certificates),
            "profile has no signing certificates")
    permitted = profile.get("Entitlements", {})
    require(isinstance(permitted, dict), "invalid profile entitlements")
    require(not permitted.get("get-task-allow")
            and not permitted.get("com.apple.security.get-task-allow"),
            "development/debug profiles cannot be used for release")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(isinstance(prefixes, list) and len(prefixes) == 1
            and isinstance(prefixes[0], str) and prefixes[0].isalnum(),
            "profile needs one unambiguous App ID prefix")
    prefix = prefixes[0] + "."
    application_id = prefix + bundle_id
    require(permitted.get(APP_ID) == application_id,
            "profile must name this explicit macOS App ID")
    require(permitted.get(TEAM_ID) == team_id, "profile entitlement has the wrong team")
    require(set(template) == {GROUPS},
            "review the profile validator before adding release entitlements")
    groups = template[GROUPS]
    require(isinstance(groups, list) and groups and all(isinstance(x, str) for x in groups),
            "keychain-access-groups must be a nonempty list of strings")
    claims = {
        APP_ID: application_id,
        TEAM_ID: team_id,
        GROUPS: [x.replace("$(AppIdentifierPrefix)", prefix) for x in groups],
    }
    for key, value in claims.items():
        require("$(" not in str(value) and "*" not in str(value),
                "unresolved or wildcard entitlement claim: " + key)
        require(key in permitted and allows(permitted[key], value),
                "profile does not authorize entitlement: " + key)
    return claims


def run(*command):
    result = subprocess.run(command, capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError(command[0] + " failed: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def decode(path):
    require(path.is_file(), "missing provisioning profile: " + str(path))
    return plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(path)))


def verify(app, template, team_id):
    profile = decode(app / "Contents/embedded.provisionprofile")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = prepare(profile, template, info["CFBundleIdentifier"], team_id)
    actual = plistlib.loads(run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)))
    require(actual == expected, "signed entitlements do not match the authorized release claims")
    run("/usr/bin/codesign", "--verify", "--strict", str(app))
    with tempfile.TemporaryDirectory(prefix="cliphoard-profile-check-") as directory:
        prefix = str(Path(directory) / "cert-")
        run("/usr/bin/codesign", "-d", "--extract-certificates", prefix, str(app))
        leaf = Path(prefix + "0").read_bytes()
    require(leaf in profile["DeveloperCertificates"],
            "profile does not authorize the app's actual signing certificate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "verify"))
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--bundle-id")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        template = plistlib.loads(args.template.read_bytes())
        if args.mode == "prepare":
            require(args.profile is not None and args.bundle_id and args.output is not None,
                    "prepare requires --profile, --bundle-id and --output")
            claims = prepare(decode(args.profile), template, args.bundle_id, args.team_id)
            args.output.write_bytes(plistlib.dumps(claims))
        else:
            require(args.app is not None, "verify requires --app")
            verify(args.app, template, args.team_id)
        print("Developer ID profile " + args.mode + ": passed")
    except (ValueError, OSError, KeyError, TypeError, plistlib.InvalidFileException,
            subprocess.TimeoutExpired) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
