"""Independent golden tokens and pooled vectors using upstream tokenizers and ONNX Runtime.
Run using Python >= 3.13 in an isolated environment with numpy, tokenizers and onnxruntime.
Only generated synthetic strings are passed through inference.
"""
from pathlib import Path
import hashlib
import json
import urllib.request
import numpy as np
import onnxruntime as ort
import tokenizers

revision = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
cache = Path('/tmp/cliphoard-parity-assets')
cache.mkdir(exist_ok=True)
base = f'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/{revision}/'
for remote, local in [('onnx/model.onnx', 'model.onnx'), ('tokenizer.json', 'tokenizer.json')]:
    path = cache / local
    if not path.exists():
        urllib.request.urlretrieve(base + remote, path)
assert hashlib.sha256((cache / 'model.onnx').read_bytes()).hexdigest() == '6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452'
tokenizer = tokenizers.Tokenizer.from_file(str(cache / 'tokenizer.json'))
tokenizer.enable_truncation(256)
tokenizer.no_padding()
session = ort.InferenceSession(str(cache / 'model.onnx'), providers=['CPUExecutionProvider'])
samples = ['Hello world!', 'café déjà vu', '中文标点。', '[CLS] hello [SEP]', 'a\x00b\tc', 'x' * 101,
           'Where can I get something to eat?', 'The restaurant serves delicious meals.', 'A compiler reports a syntax error.']
golden = []
for text in samples:
    ids = tokenizer.encode(text).ids
    inputs = {'input_ids': np.array([ids], dtype=np.int64), 'attention_mask': np.ones((1, len(ids)), dtype=np.int64), 'token_type_ids': np.zeros((1, len(ids)), dtype=np.int64)}
    hidden = session.run(None, inputs)[0]
    vector = hidden.mean(axis=1)[0]
    vector = vector / np.linalg.norm(vector)
    golden.append({'text': text, 'tokens': ids, 'vector': vector.tolist()})
output = Path(__file__).resolve().parents[1] / 'windows/NativeTests/Fixtures/Semantic.json'
output.write_text(json.dumps({'revision': revision, 'onnxruntime': ort.__version__, 'tokenizers': tokenizers.__version__, 'samples': golden}, ensure_ascii=False, indent=2) + '\n')
print(f'Generated {len(golden)} tokenizer and embedding references')
