#!/bin/bash
set -euo pipefail
# Model data only; never downloads, replaces an existing model, signs or launches.
CLIPHOARD_MODEL_SCRIPT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
export CLIPHOARD_MODEL_SCRIPT_ROOT
exec /opt/homebrew/bin/python3.13 -E - "$@" <<'PY'
from pathlib import Path
import hashlib, os, shutil, sys
assert sys.version_info >= (3, 13), 'Python 3.13+ required'
if len(sys.argv) != 3: raise SystemExit('usage: embed-media-model.sh APP.app MODEL.litertlm')
app, model = (Path(value).absolute() for value in sys.argv[1:])
expected = 'e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c'
def plain(path):
    if path != path.resolve() or any(p.is_symlink() for p in (path, *path.parents)):
        raise SystemExit('symlink path refused')
def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
plain(app); plain(model)
if app.suffix != '.app' or not app.is_dir() or (app/'Contents/_CodeSignature').exists():
    raise SystemExit('existing unsigned app required')
if any(p.name in ('Applications', 'System') for p in app.parents): raise SystemExit('installed app refused')
if any(p.suffix == '.app' for p in app.parents): raise SystemExit('nested app destination refused')
if not model.is_file() or model.stat().st_size != 484622336 or digest(model) != expected:
    raise SystemExit('model bytes do not match the pinned artifact')
folder = app/'Contents/Resources/EmbeddingGemma2'; plain(folder)
destination = folder/'embeddinggemma-2-740m.litertlm'
if destination.exists(): raise SystemExit('model destination exists; reconcile original assembly')
notice_source = Path(os.environ['CLIPHOARD_MODEL_SCRIPT_ROOT'])/'Resources/EmbeddingGemma2-NOTICE.md'
notice = app/'Contents/Resources/ThirdPartyNotices/EmbeddingGemma2-NOTICE.md'
plain(notice_source); plain(notice)
if not notice_source.is_file() or not notice_source.stat().st_size: raise SystemExit('model notice missing')
if notice.exists(): raise SystemExit('model notice destination exists; reconcile original assembly')
folder.mkdir(parents=True, exist_ok=True)
with model.open('rb') as source, destination.open('xb') as target: shutil.copyfileobj(source, target, 1048576)
destination.chmod(0o644)
if digest(destination) != expected: raise SystemExit('model copy mismatch')
notice.parent.mkdir(parents=True, exist_ok=True)
with notice.open('xb') as target: target.write(notice_source.read_bytes())
notice.chmod(0o644)
if digest(notice) != digest(notice_source): raise SystemExit('model notice copy mismatch')
print('Pinned EmbeddingGemma2 model data and notice embedded; app is not release-qualified.')
PY
