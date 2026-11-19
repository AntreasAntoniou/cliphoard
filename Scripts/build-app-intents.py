#!/usr/bin/env python3.14
"""Package compiler-produced App Intents metadata before signing the app."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.version_info < (3, 14):
    raise SystemExit("Python 3.14+ required")
parser = argparse.ArgumentParser()
parser.add_argument("--scratch", type=Path, required=True)
parser.add_argument("--configuration", choices=("debug", "release"), required=True)
parser.add_argument("--app", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
sources = sorted((root / "Sources/Cliphoard").rglob("*.swift"))
# Swift Build's executable product has one WMO const-values file per architecture.
objects = args.scratch / "out/Intermediates.noindex/Cliphoard.build" / args.configuration.title() / "Cliphoard-p.build/Objects-normal"
values = sorted(objects.glob("*/*.swiftconstvalues"))
selected = []
for path in values:
    records = json.loads(path.read_text())
    for record in records:
        if record.get("typeName") == "Cliphoard.NSFWFocusFilter":
            source = Path(record["file"]).resolve()
            if source != root / "Sources/Cliphoard/Support/NSFWFocusFilter.swift":
                raise SystemExit("Focus metadata came from a different source checkout")
            if path.stat().st_mtime_ns < source.stat().st_mtime_ns:
                raise SystemExit("Focus metadata is stale; rebuild before packaging")
            selected.append(path)
if not selected:
    raise SystemExit("No compiled Focus-filter metadata; build with -emit-const-values")
# Both slices describe the same Swift type. Pass a single architecture to avoid duplicates.
chosen = next((p for p in selected if p.parent.name == "arm64"), selected[0])
resources = args.app / "Contents/Resources"
resources.mkdir(parents=True, exist_ok=True)
if (resources / "Metadata.appintents").exists():
    raise SystemExit("Metadata output already exists; assemble a fresh bundle")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
tool = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()).parents[2]
xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines()[-1].split()[-1]
with tempfile.TemporaryDirectory(prefix="cliphoard-app-intents-") as temporary:
    temp = Path(temporary)
    (temp / "sources").write_text("\n".join(map(str, sources)) + "\n")
    (temp / "values").write_text(str(chosen.resolve()) + "\n")
    subprocess.run(["xcrun", "appintentsmetadataprocessor", "--output", str(resources),
        "--toolchain-dir", str(tool), "--module-name", "Cliphoard", "--sdk-root", sdk,
        "--xcode-version", xcode, "--platform-family", "macOS", "--deployment-target", "13.0",
        "--target-triple", chosen.parent.name + "-apple-macos13.0",
        "--source-file-list", str(temp / "sources"), "--swift-const-vals-list", str(temp / "values")], check=True)
metadata = json.loads((resources / "Metadata.appintents/extract.actionsdata").read_text())
intent = metadata["actions"]["NSFWFocusFilter"]
assert "com.apple.link.systemProtocol.FocusConfiguration" in intent["systemProtocols"]
assert any(p["name"] == "protectNSFW" for p in intent["parameters"])
print("Packaged NSFW Focus filter metadata")
