"""Publish a fully prepared environment; callers affirm that MCP clients are stopped."""
import os
import sys
from pathlib import Path
from uuid import uuid4


def activate(destination: Path, environment: Path, replace: bool) -> Path:
    destination = destination.resolve(strict=True)
    environment = environment.resolve(strict=True)
    if environment.parent != destination / "environments":
        raise ValueError("Prepared environment must be a permanent generation inside the companion directory.")
    for relative in ("bin/python", "bin/cliphoard-agent-reader", "bin/cliphoard-agent-writer", "server.py"):
        if not (environment / relative).is_file():
            raise ValueError("Prepared companion generation is incomplete.")
    targets = [destination / "venv", destination / "server.py"]
    if any(os.path.lexists(path) for path in targets) and not replace:
        raise ValueError("Stop MCP clients and pass --replace-environment to preserve and replace the old companion.")
    backups = destination / "backups" / str(uuid4())
    backups.mkdir(parents=True, mode=0o700)
    replaced = []
    try:
        for target, source in zip(targets, (environment, environment / "server.py")):
            previous = backups / target.name
            if os.path.lexists(target):
                target.rename(previous)
            replaced.append((target, previous))
            link = destination / (".activate-" + str(uuid4()))
            try:
                link.symlink_to(source)
                os.replace(link, target)
            finally:
                if os.path.lexists(link):
                    link.unlink()
    except BaseException:
        for target, previous in reversed(replaced):
            if target.is_symlink():
                target.unlink()
            if os.path.lexists(previous):
                previous.rename(target)
        raise
    return backups


if __name__ == "__main__":
    assert sys.version_info >= (3, 14), "Python 3.14 or newer is required"
    if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and sys.argv[3] != "--replace-environment"):
        raise SystemExit("Expected destination, prepared environment, and optional --replace-environment")
    activate(Path(sys.argv[1]), Path(sys.argv[2]), len(sys.argv) == 4)
    print("Companion installed. Prior generation preserved. Restart your MCP clients.")
