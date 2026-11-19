"""Capture/check the actual Mac model inventory for Windows parity qualification."""
import argparse
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
paths = ['Sources/Cliphoard/Search/ModelAssets.swift', 'Sources/Cliphoard/Search/GemmaMediaAssets.swift', 'Sources/Cliphoard/Search/MediaSpeechTranscriber.swift', 'Sources/Cliphoard/Search/DeepSearch.swift']
sources = {name: (root/name).read_text() for name in paths}
models = re.findall(r'^\s*"([^"\n]+)": Artifact\(', sources[paths[0]], re.M)
models += [re.search(r'static let filename = "([^"]+)\.litertlm"', sources[paths[1]])[1]]
models += re.findall(r'case \.\w+: return "(openai_whisper[^"]+)"', sources[paths[2]])
models += [re.search(r'let signature = "(hashing-256)"', sources[paths[3]])[1]]
assert len(set(models)) == 9, models
value = {'models': sorted(set(models)), 'sources': {name:hashlib.sha256(text.encode()).hexdigest() for name,text in sources.items()}}
path = root/'ports/windows/NativeTests/Fixtures/MacModels.json'
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
if args.check:
    assert json.loads(path.read_text()) == value, 'Mac model inventory changed'
    print('Eight downloadable Mac models and built-in matching match the Windows qualification inventory')
else:
    path.write_text(json.dumps(value,indent=2)+'\n')
    print('Captured eight Mac model families and the built-in fallback')
