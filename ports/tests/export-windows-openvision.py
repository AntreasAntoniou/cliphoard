"""Export weight-free OpenVision towers with pinned checkpoint-storage mappings and PyTorch goldens."""
import base64
import hashlib
import json
from pathlib import Path
import zipfile
import numpy as np
import onnx
import onnxruntime as ort
import open_clip
import torch
from tokenizers import BertWordPieceTokenizer

root = Path(__file__).resolve().parents[2]
source = Path('/tmp/cliphoard-model-port/openvision')
checkpoint = source / 'open_clip_pytorch_model.bin'
assert hashlib.sha256(checkpoint.read_bytes()).hexdigest() == '96ddc70bf53cece1fac63b18dd0723a67f24226785bf5e705d35ba0d5bc0bf3f'
state = torch.load(checkpoint, weights_only=True, map_location='cpu')
config = json.loads((source / 'open_clip_config.json').read_text())['model_cfg']
clip = open_clip.model.CLIP(**config).eval()
clip.load_state_dict(state, strict=True)
torch.backends.mha.set_fastpath_enabled(False)
with zipfile.ZipFile(checkpoint) as archive:
    storage = {hashlib.sha256(archive.read(name)).hexdigest(): name for name in archive.namelist() if '/data/' in name}
by_tensor = {hashlib.sha256(t.numpy().tobytes()).hexdigest(): {'entry':storage[hashlib.sha256(bytes(t.untyped_storage())).hexdigest()], 'strides':list(t.stride()), 'offset':t.storage_offset()} for t in state.values()}

class Vision(torch.nn.Module):
    def __init__(self):
        super().__init__(); self.clip = clip
        self.register_buffer('mean', torch.tensor([.485, .456, .406]).view(1,3,1,1))
        self.register_buffer('std', torch.tensor([.229, .224, .225]).view(1,3,1,1))
    def forward(self, pixels):
        return self.clip.encode_image((pixels-self.mean)/self.std, normalize=True)

class Text(torch.nn.Module):
    def __init__(self):
        super().__init__(); self.clip = clip
    def forward(self, input_ids):
        return self.clip.encode_text(input_ids, normalize=True)

models = {}
for name, model, input_name, example in [('image',Vision().eval(),'pixels',torch.zeros(1,3,224,224)),('text',Text().eval(),'input_ids',torch.zeros(1,80,dtype=torch.int64))]:
    path = source / (name+'.onnx')
    torch.onnx.export(model, (example,), str(path), dynamo=False, opset_version=18, do_constant_folding=False,
                      input_names=[input_name], output_names=['embedding'])
    graph = onnx.load(path)
    weights = []
    keep = []
    values = {}
    for tensor in graph.graph.initializer:
        digest = hashlib.sha256(tensor.raw_data).hexdigest()
        if digest not in by_tensor:
            assert tensor.name in ['mean','std'], tensor.name
            keep.append(tensor); continue
        weights.append({'name':tensor.name,**by_tensor[digest],'shape':list(tensor.dims)})
        values[tensor.name] = onnx.numpy_helper.to_array(tensor)
        graph.graph.input.append(onnx.helper.make_tensor_value_info(tensor.name,tensor.data_type,tensor.dims))
    del graph.graph.initializer[:]
    graph.graph.initializer.extend(keep)
    onnx.checker.check_model(graph)
    resource = {'source':'openvision-tiny-p8','graph':base64.b64encode(graph.SerializeToString()).decode(),'weights':weights}
    (root/'ports/windows/Cliphoard.Windows/ModelGraphs'/('openvision-'+name+'.json')).write_text(json.dumps(resource,separators=(',',':'))+'\n')
    session = ort.InferenceSession(graph.SerializeToString(),providers=['CPUExecutionProvider'])
    models[name] = (model,session,values)

tokenizer = BertWordPieceTokenizer(str(source/'vocab.txt'),lowercase=True)
tokenizer.enable_truncation(80)
samples = []
for text in ['a red picture','a blue picture','a green picture','Hello world!','café 中文']:
    ids = tokenizer.encode(text).ids
    ids += [0]*(80-len(ids))
    inputs = np.array([ids],dtype='int64')
    model, session, weights = models['text']
    with torch.no_grad(): reference=model(torch.from_numpy(inputs)).numpy()[0]
    actual=session.run(None,{**weights,'input_ids':inputs})[0][0]
    assert np.dot(reference,actual)>.99999
    samples.append({'text':text,'tokens':ids,'vector':reference.tolist()})
images=[]
for index in range(3):
    pixels=np.zeros((1,3,224,224),dtype='float32');pixels[:,index,:,:]=1
    model,session,weights=models['image']
    with torch.no_grad():reference=model(torch.from_numpy(pixels)).numpy()[0]
    actual=session.run(None,{**weights,'pixels':pixels})[0][0]
    assert np.dot(reference,actual)>.99999
    images.append({'channel':index,'vector':reference.tolist()})
(root/'ports/windows/NativeTests/Fixtures/OpenVision.json').write_text(json.dumps({'text':samples,'images':images},separators=(',',':'))+'\n')
print('OpenVision both towers weight-free graph and PyTorch parity passed')
