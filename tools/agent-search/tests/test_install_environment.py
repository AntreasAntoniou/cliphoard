"""Synthetic existing environment migration; never executes an older interpreter."""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "install_environment.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert sys.version_info >= (3, 14)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary).resolve()
    old = root / "venv"
    (old / "bin").mkdir(parents=True)
    (old / "bin/python").write_text("old interpreter placeholder, must never execute")
    (root / "server.py").write_text("old server")
    new = root / "environments" / "new-generation"
    (new / "bin").mkdir(parents=True)
    (new / "bin/python").symlink_to(sys.executable)
    for file in ("bin/cliphoard-agent-reader", "bin/cliphoard-agent-writer", "server.py"):
        (new / file).write_text("new prepared fixture")
    try:
        module.activate(root, new, False)
        raise AssertionError("missing client-stop assertion accepted")
    except ValueError:
        pass
    assert (old / "bin/python").read_text().startswith("old interpreter")
    backup = module.activate(root, new, True)
    assert (backup / "venv/bin/python").read_text().startswith("old interpreter")
    assert (backup / "server.py").read_text() == "old server"
    assert old.resolve() == new
    assert (root / "server.py").resolve() == new / "server.py"
    subprocess.run([str(old / "bin/python"), "-c", "import sys; assert sys.version_info >= (3,14)"], check=True)
print("PASS installer: client-stop acknowledgment, old generation preservation, stable aliases to permanent new generation, verified Python 3.14")
