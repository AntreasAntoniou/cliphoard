"""Export weight-free ONNX graphs from the pinned, reviewed Ogma source and checkpoints.
Use Python >=3.13 with torch, sentencepiece, safetensors, onnx and onnxruntime.
Inputs live outside the repository. Model weights are never written to release resources.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import onnx
import onnxruntime as ort
import sentencepiece as spm
import torch
from safetensors.torch import load_file

parser = argparse.ArgumentParser()
parser.add_argument('checkpoint', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
checkpoint = args.checkpoint.resolve()
sys.path.insert(0, str(checkpoint))
from ogma_libre import OgmaLibre

class BothHeads(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.base = model.base
        self.proj_small = model.proj_small
        self.proj_large = model.proj_large

    def forward(self, input_ids, attention_mask, task_token_ids):
        trunk = self.base(input_ids, attention_mask, task_token_ids)
        return (torch.nn.functional.normalize(self.proj_small(trunk), dim=-1),
                torch.nn.functional.normalize(self.proj_large(trunk), dim=-1))

model = OgmaLibre.from_repo(str(checkpoint), device='cpu')
wrap = BothHeads(model).eval()
ids = torch.tensor([[2, 100, 200, 3]], dtype=torch.int64)
mask = torch.ones_like(ids)
task = torch.tensor([5], dtype=torch.int64)
path = checkpoint / 'windows-reference.onnx'
torch.onnx.export(wrap, (ids, mask, task), str(path), dynamo=False, opset_version=18,
                  input_names=['input_ids', 'attention_mask', 'task_token_ids'],
                  output_names=['embedding', 'embedding_large'],
                  dynamic_axes={'input_ids': {1: 'sequence'}, 'attention_mask': {1: 'sequence'}},
                  do_constant_folding=False)
graph = onnx.load(path)
state = load_file(checkpoint / 'model.safetensors')
by_hash = {hashlib.sha256(t.numpy().tobytes()).hexdigest(): name for name, t in state.items()}
weights = []
for tensor in graph.graph.initializer:
    digest = hashlib.sha256(tensor.raw_data).hexdigest()
    if digest not in by_hash:
        raise RuntimeError(f'Unmapped model initializer {tensor.name}')
    name = by_hash[digest]
    weights.append({'name': tensor.name, 'tensor': name, 'shape': list(tensor.dims)})
    graph.graph.input.append(onnx.helper.make_tensor_value_info(tensor.name, tensor.data_type, tensor.dims))
del graph.graph.initializer[:]
# Validate actual dynamic inference before emitting the weight-free artifact.
session = ort.InferenceSession(graph.SerializeToString(), providers=['CPUExecutionProvider'])
weight_inputs = {entry['name']: state[entry['tensor']].numpy() for entry in weights}
samples = ['Hello world!', 'café déjà vu', '中文标点。', 'emoji 🦄👩‍💻', 'line one\nsecond\tline',
           'Where can I get something to eat?', 'The restaurant serves delicious meals.',
           'A compiler reports a syntax error.', 'x' * 600]
goldens = []
for text in samples:
    encoded = model.tokenizer.batch_encode([text], max_length=256)
    for token in [4, 5, 6]:
        inputs = {'input_ids': encoded['input_ids'].astype('int64'),
                  'attention_mask': encoded['attention_mask'].astype('int64'),
                  'task_token_ids': np.array([token], dtype='int64')}
        with torch.no_grad():
            reference = wrap(*(torch.from_numpy(inputs[k]) for k in ['input_ids', 'attention_mask', 'task_token_ids']))
        actual = session.run(None, {**weight_inputs, **inputs})
        for index in range(2):
            cosine = np.dot(actual[index][0], reference[index].numpy()[0])
            assert cosine > .99999, (checkpoint.name, text, token, cosine)
        goldens.append({'text': text, 'task': token, 'tokens': inputs['input_ids'][0].tolist(),
                        'small': reference[0].numpy()[0].tolist(), 'large': reference[1].numpy()[0].tolist()})
resource = {'source': checkpoint.name, 'graph': base64.b64encode(graph.SerializeToString()).decode(), 'weights': weights}
(root / 'ports/windows/Cliphoard.Windows/ModelGraphs' / (checkpoint.name + '.json')).write_text(json.dumps(resource, separators=(',', ':'))+'\n')
(root / 'ports/windows/NativeTests/Fixtures' / (checkpoint.name + '.json')).write_text(json.dumps({'samples': goldens}, separators=(',', ':'))+'\n')
sp = spm.SentencePieceProcessor(model_file=str(checkpoint / 'tokenizer/ogma_sp.model'))
vocab = [[sp.id_to_piece(i), sp.get_score(i)] for i in range(sp.get_piece_size())]
(root / 'ports/windows/Cliphoard.Windows/ModelGraphs/OgmaTokenizer.json').write_text(json.dumps(vocab, ensure_ascii=False, separators=(',', ':'))+'\n')
print(checkpoint.name, len(weights), 'weight inputs', len(goldens), 'PyTorch parity cases')
