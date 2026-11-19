"""Fetch one generated qualification artifact without enabling VM file sharing."""
import argparse
import base64
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import uuid

if sys.version_info < (3, 13):
    raise SystemExit("Python 3.13 or newer required")
parser = argparse.ArgumentParser()
parser.add_argument("source")
parser.add_argument("destination", type=Path)
parser.add_argument("sha256")
args = parser.parse_args()
if not re.fullmatch(r"C:\\CliphoardDev\\qualified-[A-Za-z0-9._-]+\\Cliphoard-[0-9.]+-(arm64|x64)\.(msi|zip)", args.source):
    raise SystemExit("Only generated qualification packages may be fetched")
if not re.fullmatch(r"[0-9A-Fa-f]{64}", args.sha256) or args.destination.exists():
    raise SystemExit("Expected SHA-256 required; destination must be new")
args.destination.parent.mkdir(parents=True, exist_ok=True)
temporary = args.destination.with_name(args.destination.name + ".partial-" + uuid.uuid4().hex)
offset = 0
digest = hashlib.sha256()
try:
    with temporary.open("xb") as output:
        while True:
            script = f"""$ErrorActionPreference='Stop'
$file=[IO.File]::OpenRead('{args.source}')
try {{
 $null=$file.Seek({offset},[IO.SeekOrigin]::Begin)
 $buffer=New-Object byte[] 4194304
 $count=$file.Read($buffer,0,$buffer.Length)
 [Console]::Write([Convert]::ToBase64String($buffer,0,$count))
}} finally {{ $file.Dispose() }}
"""
            for attempt in range(3):
                result = subprocess.run([
                    "/usr/local/bin/prlctl", "exec", "ad50825b-955a-4cd4-a04b-b7fadc860197",
                    "--current-user", "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "-",
                ], input="& {\n" + script + "\n}\n\n", capture_output=True, text=True, timeout=60)
                if result.returncode == 0:
                    break
            if result.returncode:
                raise RuntimeError("Guest transfer failed at offset " + str(offset) + ": " + result.stderr[:300])
            chunk = base64.b64decode(result.stdout.strip(), validate=True)
            if not chunk:
                break
            if len(chunk) > 4194304:
                raise RuntimeError("Oversized guest transfer chunk")
            output.write(chunk)
            digest.update(chunk)
            offset += len(chunk)
            print(f"Fetched {offset} bytes", flush=True)
    if digest.hexdigest().lower() != args.sha256.lower():
        raise RuntimeError("Artifact SHA-256 mismatch")
    temporary.rename(args.destination)
    print(f"Verified {args.destination} ({offset} bytes)")
finally:
    temporary.unlink(missing_ok=True)
