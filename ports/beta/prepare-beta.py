"""Assemble reviewed local beta kits from hash-pinned MSI artifacts. Python 3.13+."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import zipfile

if sys.version_info < (3, 13):
    raise SystemExit("Python 3.13 or newer required")
parser = argparse.ArgumentParser()
parser.add_argument("artifact_directory", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = args.artifact_directory.resolve()
version = "1.2.14.0"
pins = {
    "arm64": "D00346A80D6D17A4B0A2517E0F8D7080660239A29F509C6E91E3FA64006085E1",
    "x64": "79364DBD1506B883784B4BC7BD7C05262A1F3986CF5C76B0FA8B23E7E3EC56C2",
}
def sha(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest().upper()

for arch, expected in pins.items():
    msi = output / arch / f"Cliphoard-{version}-{arch}.msi"
    if sha(msi) != expected:
        raise SystemExit(f"Installer hash mismatch: {arch}")
    with msi.open("rb") as source:
        if source.read(8) != bytes.fromhex("D0CF11E0A1B11AE1"):
            raise SystemExit(f"Not an MSI compound file: {arch}")

kits = output / "kits"
kits.mkdir(exist_ok=False)
archives = {}
documents = ["START-HERE.md", "KNOWN-ISSUES.md", "TEST-PLAN.md", "BUG-REPORT.md", "RELEASE-NOTES.md"]
for arch, expected in pins.items():
    name = f"Cliphoard-Windows-1.2.14-private-beta-{arch}"
    folder = kits / name
    folder.mkdir()
    msi_name = f"Cliphoard-{version}-{arch}.msi"
    shutil.copyfile(output / arch / msi_name, folder / msi_name)
    for document in documents:
        shutil.copyfile(root / "ports/beta" / document, folder / document)
    shutil.copyfile(root / "LICENSE", folder / "LICENSE.txt")
    checksums = {file.name: sha(file) for file in sorted(folder.iterdir())}
    (folder / "SHA256SUMS.txt").write_text("".join(f"{value}  {key}\n" for key, value in checksums.items()))
    archive = output / (name + ".zip")
    if archive.exists():
        raise SystemExit("Refusing to replace an existing beta archive")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_STORED) as package:
        for file in sorted(folder.iterdir()):
            package.write(file, f"{name}/{file.name}")
    with zipfile.ZipFile(archive) as package:
        if package.testzip() is not None:
            raise SystemExit("Beta archive CRC failure")
        for filename, expected_hash in checksums.items():
            actual = hashlib.sha256(package.read(f"{name}/{filename}")).hexdigest().upper()
            if actual != expected_hash:
                raise SystemExit("Beta archive content mismatch")
    archives[archive.name] = {"sha256": sha(archive), "bytes": archive.stat().st_size, "architecture": arch}
    print(f"Verified beta kit: {archive.name}")

# Keep an internal source snapshot so uncommitted work has durable provenance.
# Only repository-selected Windows sources and the two asset generators are included.
paths = subprocess.check_output([
    "git", "ls-files", "--cached", "--others", "--exclude-standard", "ports/windows",
    "Scripts/make-windows-icons.swift", "Scripts/make-copy-sounds.py", "ports/beta", "LICENSE",
], cwd=root, text=True).splitlines()
inventory = {path: sha(root / path) for path in sorted(set(paths)) if (root / path).is_file()}
snapshot = output / "source-snapshot.tar.gz"
with tarfile.open(snapshot, "x:gz") as archive:
    for path in inventory:
        archive.add(root / path, arcname=path, recursive=False)
(output / "source-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
manifest = {
    "application_version": version, "channel": "private-beta", "prepared_date": "2026-11-19",
    "authenticode_signed": False, "msix_included": False,
    "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "source_state": "working tree captured in source-snapshot.tar.gz; not a clean committed release",
    "source_snapshot_sha256": sha(snapshot), "source_inventory_sha256": sha(output / "source-inventory.json"),
    "installer_sha256": pins, "tester_kits": archives,
    "qualification": {
        "arm64": "Windows 11 VM; installed upgrade and synthetic fixtures",
        "x64": "ARM64 emulation; native Intel/AMD and fresh-install qualification outstanding",
        "search_quality": "41 failed expectations across 432 synthetic queries; unresolved",
        "publisher_signing": "outstanding", "published": False,
    },
}
(output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(output / "SHA256SUMS.txt").write_text("".join(f"{entry['sha256']}  {name}\n" for name, entry in archives.items()))
print("Source snapshot, release manifest and external checksums saved")
