#!/opt/homebrew/bin/python3.13
"""Read-only future-bundle policy: known code/resources only, never model payloads.

This is an assembly allowlist, not a forensic claim about arbitrary executable bytes.
New resources require an explicit policy update. No archives or opaque data assets are
allowed in Resources, including renamed weights. Hub's tiny tokenizer defaults are
runtime configuration, not learned weights or complete tokenizer vocabularies.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys

if sys.version_info < (3, 13):
    raise SystemExit("Python 3.13+ required")


class PolicyError(ValueError):
    pass


def check_environment(environment):
    for name in ("BUNDLE_MODELS", "MAS_BUNDLE_MODELS", "MAS_MEDIA_MODEL", "CLIPHOARD_MEDIA_MODEL"):
        if environment.get(name, ""):
            raise PolicyError(f"{name} is retired: model weights download after installation; no bundling override")


TEXT_RESOURCES = {"LICENSE", "LICENSE-Apache-2.0.txt", "THIRD-PARTY-NOTICES.md"}
HUB_NAMES = {"swift-transformers_Hub.bundle", "swift_transformers_Hub.bundle"}
HUB_CONFIGS = {
    "gpt2_tokenizer_config.json": "551e26ec611d8d0c8edc3ef72e518a38418cb71f40de1347dd486a595e1557d7",
    "t5_tokenizer_config.json": "e0aff0b1de9071e30d9a60a199303b6abe916a64a19932bd1c46992279b41a1f",
}
# These are the exact public runtime notices copied by embed-media-runtime.sh.
# Content pins prevent a permitted text/JSON name becoming an arbitrary data channel.
NOTICE_PINS = {
    "LiteRTLM-LICENSE.txt": "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
    "LiteRTLM/LiteRT-LICENSE.txt": "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
    "LiteRTLM/MANIFEST.json": "adc23d53bd8372bead0d843fa526969c147f0f2ad9aa04bb1cb7b45d76cc3cc3",
    "LiteRTLM/README.md": "38d84b621793825f370ce507e39feb9657c7bffe98b687bffb043446ea7d6cbc",
    "LiteRTLM/XNNPACK-LICENSE.txt": "63f519e15726f4c4f830bd958f694c84fecb4e0a4cacc527d2696bb71ef95ada",
    "LiteRTLM/abseil-LICENSE.txt": "c79a7fea0e3cac04cd43f20e7b648e5a0ff8fa5344e644b0ee09ca1162b62747",
    "LiteRTLM/dawn-LICENSE.txt": "0493f897193af1796d5054659f45ec7d4c5af648fa67a99f01d30e55cc805abc",
    "LiteRTLM/miniaudio-LICENSE.txt": "457f1b500e0adf6bc059edddfa78a2f62012e7c3bb43476c20e0bd23b25ba0eb",
    "LiteRTLM/nlohmann-json-MIT.txt": "46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603",
    "LiteRTLM/sentencepiece-LICENSE.txt": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
    "LiteRTLM/stb-LICENSE.txt": "bebfe904b14301657e4e5d655c811d51fd31b97c455b9cc2d8600d6bac6cff63",
}
HUB_PLIST_KEYS = {
    "BuildMachineOSBuild", "CFBundleDevelopmentRegion", "CFBundleIdentifier", "CFBundleInfoDictionaryVersion",
    "CFBundleName", "CFBundlePackageType", "CFBundleSupportedPlatforms", "DTCompiler", "DTPlatformBuild",
    "DTPlatformName", "DTPlatformVersion", "DTSDKBuild", "DTSDKName", "DTXcode", "DTXcodeBuild", "LSMinimumSystemVersion",
}
MACHO_MAGICS = {bytes.fromhex(x) for x in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def bounded_data(path, maximum=1_048_576):
    if path.stat().st_size > maximum:
        raise PolicyError(f"resource exceeds policy size: {path.name}")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise PolicyError("resource grew during audit")
    return data


def text_resource(path):
    data = bounded_data(path)
    text = data.decode("utf-8")
    if not text or any(ord(c) < 32 and c not in "\n\r\t" for c in text):
        raise PolicyError(f"non-text notice: {path.name}")


def allowed_file(relative, path):
    parts = relative.parts
    if relative.as_posix() in ("Contents/MacOS/Cliphoard", "Contents/Frameworks/libCLiteRTLM_mac.dylib"):
        with path.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGICS:
                raise PolicyError("expected Mach-O code")
        return
    if relative.as_posix() in ("Contents/Info.plist", "Contents/_CodeSignature/CodeResources"):
        if not isinstance(plistlib.loads(bounded_data(path)), dict):
            raise PolicyError("invalid bundle/signature plist")
        return
    if relative.as_posix() == "Contents/embedded.provisionprofile":
        if not bounded_data(path):
            raise PolicyError("empty provisioning profile")
        return
    if len(parts) < 3 or parts[:2] != ("Contents", "Resources"):
        raise PolicyError(f"unapproved bundle file: {relative}")
    resource = parts[2:]
    if len(resource) == 1 and resource[0] in TEXT_RESOURCES:
        text_resource(path)
        return
    if resource == ("Cliphoard.icns",):
        data = bounded_data(path, 16 * 1_048_576)
        if len(data) < 8 or data[:4] != b"icns" or int.from_bytes(data[4:8], "big") != len(data):
            raise PolicyError("invalid icon container")
        return
    if resource == ("PrivacyInfo.xcprivacy",):
        if not isinstance(plistlib.loads(bounded_data(path)), dict):
            raise PolicyError("invalid privacy manifest")
        return
    if resource[0] == "ThirdPartyNotices":
        pin = NOTICE_PINS.get("/".join(resource[1:]))
        if pin is None or hashlib.sha256(bounded_data(path)).hexdigest() != pin:
            raise PolicyError("unapproved or altered runtime notice")
        return
    if resource[0] in HUB_NAMES:
        if resource[1:] == ("Contents", "Info.plist"):
            info = plistlib.loads(bounded_data(path, 16_384))
            if (not isinstance(info, dict) or set(info) - HUB_PLIST_KEYS
                    or info.get("CFBundleIdentifier") != "swift-transformers.Hub.resources"
                    or info.get("CFBundlePackageType") != "BNDL"):
                raise PolicyError("invalid Hub plist schema")
            for key, value in info.items():
                if key == "CFBundleSupportedPlatforms":
                    if value != ["MacOSX"]:
                        raise PolicyError("invalid Hub platform")
                elif not isinstance(value, str) or not 0 < len(value) <= 128:
                    raise PolicyError("invalid Hub metadata value")
            return
        if len(resource) == 4 and resource[1:3] == ("Contents", "Resources") and resource[3] in HUB_CONFIGS:
            if hashlib.sha256(bounded_data(path, 65_536)).hexdigest() != HUB_CONFIGS[resource[3]]:
                raise PolicyError("altered Hub tokenizer defaults")
            return
    raise PolicyError(f"unapproved resource (model payloads are prohibited): {relative}")


def allowed_directory(relative):
    parts = relative.parts
    if relative.as_posix() in ("Contents", "Contents/MacOS", "Contents/Frameworks", "Contents/Resources", "Contents/_CodeSignature"):
        return True
    if parts[:3] == ("Contents", "Resources", "ThirdPartyNotices"):
        return parts[3:] in ((), ("LiteRTLM",))
    return len(parts) in (3, 4, 5) and parts[:2] == ("Contents", "Resources") and parts[2] in HUB_NAMES and parts[3:] in ((), ("Contents",), ("Contents", "Resources"))


def audit_bundle(app):
    app = Path(app).absolute()
    if app != app.resolve() or app.suffix != ".app" or not app.is_dir():
        raise PolicyError("canonical nonsymlink .app directory required")
    files = 0
    entries = 0
    # Never follow symlinks; fail closed on unknown directories before descending.
    pending = [app]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as children:
            for entry in children:
                entries += 1
                if entries > 1000:
                    raise PolicyError("bundle entry limit exceeded")
                p = Path(entry.path)
                relative = p.relative_to(app)
                mode = entry.stat(follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode):
                    if not allowed_directory(relative):
                        raise PolicyError(f"unapproved directory: {relative}")
                    pending.append(p)
                elif stat.S_ISREG(mode):
                    allowed_file(relative, p)
                    files += 1
                else:
                    raise PolicyError(f"symlink or special entry refused: {relative}")
    info = plistlib.loads(bounded_data(app / "Contents/Info.plist"))
    if info.get("CFBundleExecutable") != "Cliphoard" or not (app / "Contents/MacOS/Cliphoard").is_file():
        raise PolicyError("Cliphoard executable contract missing")
    return {"policy": "download-only-models-v1", "filesChecked": files, "entriesChecked": entries,
            "modelWeightsAllowed": False, "runtimeCodeAndTokenizerDefaultsAllowed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?")
    parser.add_argument("--check-environment", action="store_true")
    args = parser.parse_args()
    try:
        check_environment(os.environ)
        if args.app:
            print(json.dumps(audit_bundle(args.app), sort_keys=True))
        elif not args.check_environment:
            parser.error("APP.app or --check-environment required")
    except (PolicyError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"no-model bundle audit: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
