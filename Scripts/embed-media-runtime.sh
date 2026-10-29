#!/bin/bash
set -euo pipefail
# Copy-only assembly of the pinned runtime into a NEW, unsigned app. Does not sign or launch.
CLIPHOARD_EMBED_SCRIPT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
export CLIPHOARD_EMBED_SCRIPT_ROOT
CLIPHOARD_EMBED_PYTHON="${CLIPHOARD_PYTHON:-/opt/homebrew/bin/python3.13}"
exec "$CLIPHOARD_EMBED_PYTHON" -E - "$@" <<'PY'
from pathlib import Path
import hashlib, json, os, plistlib, shutil, stat, subprocess, sys
if sys.version_info < (3, 13): raise SystemExit('Python 3.13+ required')
if len(sys.argv) != 3: raise SystemExit('usage: embed-media-runtime.sh APP.app BIN_DIR')
app, binaries = (Path(x).absolute() for x in sys.argv[1:])
# The caller's cwd is not trusted for notices; use this repository-relative script path passed by shell.
expected = '9968711bd9e7f386308f86a2d48c38a8c422d4f1a3bc4fb444276f11b7c790ac'
def fail(message): raise SystemExit(message)
def digest(p):
    with p.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def plain(p):
    if p != p.resolve() or any(x.is_symlink() for x in (p, *p.parents)): fail('symlink path refused')
    return p
def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=15).stdout
plain(app); plain(binaries)
if app.suffix != '.app' or not app.is_dir() or not binaries.is_dir(): fail('existing app and binary directory required')
if any(x.name in ('Applications', 'System') for x in app.parents): fail('installed/system app destination refused')
if any(x.suffix == '.app' for x in app.parents): fail('nested app destination refused')
if (app/'Contents/_CodeSignature').exists(): fail('already signed app refused')
if any(p.name != 'Contents' for p in app.iterdir()): fail('app root must contain only Contents')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
name = info.get('CFBundleExecutable')
if not isinstance(name,str) or Path(name).name != name: fail('invalid executable name')
exe = plain(app/'Contents/MacOS'/name)
lib = plain(binaries/'libCLiteRTLM_mac.dylib')
if not exe.is_file() or not lib.is_file() or digest(lib) != expected: fail('pinned runtime/executable missing or mismatched')
if set(run(['/usr/bin/lipo','-archs',str(lib)]).split()) != {'arm64','x86_64'}: fail('runtime must be universal')
if '@rpath/libCLiteRTLM_mac.dylib' not in run(['/usr/bin/otool','-L',str(exe)]): fail('executable does not link pinned runtime')
frameworks = plain(app/'Contents/Frameworks'); resources = plain(app/'Contents/Resources')
dest = frameworks/lib.name
if dest.exists(): fail('runtime destination exists; reconcile original assembly instead of overwriting')
# The generated macOS app accessor prefers Bundle.main.resourceURL (Contents/Resources).
# Its bundle-root candidate is only a CLI fallback and is invalid in a signed .app root.
hubs = [p for p in binaries.glob('*.bundle') if p.name in ('swift-transformers_Hub.bundle','swift_transformers_Hub.bundle')]
if len(hubs) != 1: fail('exactly one production Transformers Hub resource bundle required')
for bundle in hubs:
    plain(bundle)
    for p in bundle.rglob('*'):
        if p.is_symlink() or not (p.is_file() or p.is_dir()): fail('nonregular resource entry refused')
def inventory(folder):
    return {str(p.relative_to(folder)): (stat.S_IMODE(p.stat().st_mode), digest(p) if p.is_file() else 'directory')
            for p in folder.rglob('*')}
for bundle in hubs:
    for target in (resources/bundle.name,):
        plain(target)
        if target.exists() and inventory(target) != inventory(bundle): fail('existing resource bundle differs')
# Locate notices from an explicit repository path in this script's sibling Vendor folder.
notice_source = Path(os.environ['CLIPHOARD_EMBED_SCRIPT_ROOT'])/'Vendor/LiteRTLM/LICENSE'
plain(notice_source)
if not notice_source.is_file() or digest(notice_source) != 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4': fail('pinned runtime license missing/mismatched')
notice = resources/'ThirdPartyNotices/LiteRTLM-LICENSE.txt'
plain(notice)
if notice.exists() and notice.read_bytes() != notice_source.read_bytes(): fail('existing license differs')
# Supplemental upstream notices are fixed public text, validated before any assembly mutation.
supplemental_root = notice_source.parent/'Notices'
supplemental_pins = {'LiteRT-LICENSE.txt': 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4', 'MANIFEST.json': 'adc23d53bd8372bead0d843fa526969c147f0f2ad9aa04bb1cb7b45d76cc3cc3', 'README.md': '38d84b621793825f370ce507e39feb9657c7bffe98b687bffb043446ea7d6cbc', 'XNNPACK-LICENSE.txt': '63f519e15726f4c4f830bd958f694c84fecb4e0a4cacc527d2696bb71ef95ada', 'abseil-LICENSE.txt': 'c79a7fea0e3cac04cd43f20e7b648e5a0ff8fa5344e644b0ee09ca1162b62747', 'dawn-LICENSE.txt': '0493f897193af1796d5054659f45ec7d4c5af648fa67a99f01d30e55cc805abc', 'miniaudio-LICENSE.txt': '457f1b500e0adf6bc059edddfa78a2f62012e7c3bb43476c20e0bd23b25ba0eb', 'nlohmann-json-MIT.txt': '46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603', 'sentencepiece-LICENSE.txt': 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30', 'stb-LICENSE.txt': 'bebfe904b14301657e4e5d655c811d51fd31b97c455b9cc2d8600d6bac6cff63'}
supplemental = []
for name, expected_hash in supplemental_pins.items():
    source = plain(supplemental_root/name)
    target = plain(resources/'ThirdPartyNotices/LiteRTLM'/name)
    if not source.is_file() or digest(source) != expected_hash: fail('supplemental runtime notice missing/mismatched')
    if target.exists() and target.read_bytes() != source.read_bytes(): fail('existing supplemental notice differs')
    supplemental.append((source, target))
rpath = '@executable_path/../Frameworks'
architectures = run(['/usr/bin/lipo','-archs',str(exe)]).split()
present = [rpath in run(['/usr/bin/otool','-arch',arch,'-l',str(exe)]) for arch in architectures]
if any(present) and not all(present): fail('mixed architecture rpaths require explicit reconciliation')
added = not all(present)
frameworks.mkdir(parents=True, exist_ok=True); resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(lib,dest)
if digest(dest) != expected: fail('runtime copy mismatch')
for bundle in hubs:
    for target in (resources/bundle.name,):
        if not target.exists(): shutil.copytree(bundle,target,copy_function=shutil.copy2)
        if inventory(target) != inventory(bundle): fail('resource copy mismatch')
notice.parent.mkdir(parents=True,exist_ok=True)
if not notice.exists():
    with notice.open('xb') as f:f.write(notice_source.read_bytes())
for source, target in supplemental:
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        with target.open('xb') as f: f.write(source.read_bytes())
    if digest(target) != digest(source): fail('supplemental notice copy mismatch')
if added: run(['/usr/bin/install_name_tool','-add_rpath',rpath,str(exe)])
if not all(rpath in run(['/usr/bin/otool','-arch',arch,'-l',str(exe)]) for arch in architectures): fail('runtime search path readback failed')
print(json.dumps({'state':'embedded_unsigned','runtimeSHA256':expected,'runtime':str(dest),'rpath':rpath,'addedRpath':added,'resources':[x.name for x in hubs],'resourceLookupLocations':['Contents/Resources'],'supplementalRuntimeNotices':len(supplemental),'completeBinarySBOMClaim':False,'whisperKitProductionResourceBundleRequired':False,'next':'sign nested dylib, then enclosing app; strict verify before distribution'}))
PY
