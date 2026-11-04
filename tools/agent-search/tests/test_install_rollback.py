"""A partial local activation restores the original aliases; no real installation."""
import importlib.util
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "install_environment.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary).resolve()
    (root / "venv/bin").mkdir(parents=True)
    (root / "venv/bin/python").write_text("old preserved placeholder")
    (root / "server.py").write_text("old server")
    new = root / "environments/new"
    (new / "bin").mkdir(parents=True)
    (new / "bin/python").symlink_to(sys.executable)
    for name in ("bin/cliphoard-agent-reader", "bin/cliphoard-agent-writer", "server.py"):
        (new / name).write_text("new fixture")
    original = module.os.replace
    def replace(source, target):
        if Path(target).name == "server.py":
            raise OSError("synthetic publication failure")
        return original(source, target)
    with patch.object(module.os, "replace", replace):
        try:
            module.activate(root, new, True)
            raise AssertionError("failure not injected")
        except OSError:
            pass
    assert not (root / "venv").is_symlink()
    assert (root / "venv/bin/python").read_text() == "old preserved placeholder"
    assert (root / "server.py").read_text() == "old server"
    assert new.is_dir()
    assert not list(root.glob(".activate-*"))
print("PASS installer rollback: original environment/server restored after second alias switch failure; new generation retained")
