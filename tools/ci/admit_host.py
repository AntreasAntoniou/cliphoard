"""Check the selected hosted toolchain before spending time on a native build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

DEVELOPER = "/Applications/Xcode_26.6.app/Contents/Developer"


def checked(command, environment):
    return subprocess.run(command, env=environment, text=True, capture_output=True,
                          check=True, timeout=10).stdout.strip()


def require(value, message):
    if not value:
        raise ValueError(message)


def main():
    require(sys.version_info[:3] == (3, 14, 6), "explicit Python3.14.6 required")
    parser = argparse.ArgumentParser()
    parser.add_argument("--python313", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "Darwin arm64 required")
    require(os.environ.get("DEVELOPER_DIR") == DEVELOPER and Path(DEVELOPER).is_dir(), "selected Xcode required")
    # Only public toolchain discovery is performed here; no native package import.
    env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "DEVELOPER_DIR": DEVELOPER}
    if "HOME" in os.environ:
        env["HOME"] = os.environ["HOME"]
    paths = {name: shutil.which(name, path=env["PATH"]) for name in ("cmake", "ninja")}
    require(all(paths.values()), "build tools unavailable")
    paths = {name: str(Path(value).resolve(strict=True)) for name, value in paths.items()}
    paths.update({name: checked(["/usr/bin/xcrun", "--sdk", "macosx", "--find", tool], env)
                  for name, tool in (("cc", "clang"), ("cxx", "clang++"))})
    paths["sdk"] = checked(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env)
    require(all(Path(value).is_absolute() and "\n" not in value for value in paths.values()), "invalid tool path")
    require(all(Path(paths[name]).resolve(strict=True).is_relative_to(Path(DEVELOPER).resolve(strict=True))
                for name in ("cc", "cxx", "sdk")), "compiler and SDK must belong to selected Xcode")
    versions = {"cmake": checked([paths["cmake"], "--version"], env),
                "ninja": checked([paths["ninja"], "--version"], env),
                "clang": checked([paths["cc"], "--version"], env),
                "sdk": checked(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], env),
                "xcode": checked(["/usr/bin/xcodebuild", "-version"], env)}
    require(versions["cmake"].splitlines()[0] == "cmake version 4.4.4", "unsupported hosted CMake")
    require(versions["ninja"] == "1.13.2", "unsupported hosted Ninja")
    require(versions["sdk"] == "26.5", "unsupported hosted SDK")
    require(versions["xcode"].splitlines() == ["Xcode 26.6", "Build version 17F113"], "unsupported hosted Xcode")
    # The inventory's generic LLVM version is not proof of the selected Xcode's
    # compiler version. Bind its owning bundle, then retain its actual identity.
    require(re.match(r"Apple clang version [0-9]+\.[0-9]+\.[0-9]+\b", versions["clang"]) is not None, "Apple compiler identity required")
    native = args.python313.resolve(strict=True)
    require(args.python313.is_absolute() and native.is_file(), "explicit native interpreter required")
    native_identity = checked([str(native), "-I", "-B", "-c",
                              "import json,platform,sys; print(json.dumps([list(sys.version_info[:3]),platform.machine(),sys.prefix]))"], env)
    version, arch, prefix = json.loads(native_identity)
    require(version == [3, 13, 13] and arch == "arm64", "CoreML compatibility interpreter mismatch")
    record = {"system": platform.platform(), "architecture": platform.machine(),
              "imageVersion": os.environ.get("ImageVersion"), "paths": paths, "versions": versions,
              "python313": {"path": str(native), "version": version, "prefix": prefix,
                            "sha256": hashlib.sha256(native.read_bytes()).hexdigest()},
              "python314": {"path": sys.executable, "version": list(sys.version_info[:3]),
                            "sha256": hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest()},
              "qualification": "Hosted tools differ from local comparison; this job must qualify its own native output."}
    with args.report.open("x") as report:
        json.dump(record, report, indent=2, sort_keys=True)
        report.write("\n")
    # Only fixed, validated local tool paths enter the Actions output file.
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        for name, value in paths.items():
            output.write(f"{name}={value}\n")
    print("Hosted architecture, exact runtimes and selected compiler/SDK admitted.")


if __name__ == "__main__":
    main()
