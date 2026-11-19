"""Synthetic Gemma references through the official macOS LiteRT-LM C API."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import zipfile
from PIL import Image

root=Path(__file__).resolve().parents[2]
cache=Path('/tmp/cliphoard-model-port')
archive=cache/'litert-capi.zip'
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='1d430d80eaf536f696a4922270ba55eb3d112189ac198c3066d487a45e3b4d4c'
with zipfile.ZipFile(archive) as z:
    libpath=cache/'liblitert-lm.dylib'
    libpath.write_bytes(z.read('lib/macos_arm64/liblitert-lm.dylib'))
lib=c.CDLL(str(libpath))
def function(name,args):
    f=getattr(lib,'litert_lm_'+name);f.restype=c.c_int;f.argtypes=args;return f
def check(status):
    if status:raise RuntimeError('LiteRT-LM status '+str(status))
pointer=c.c_void_p
out=c.POINTER(pointer)
settings=pointer();engine=pointer();options=pointer()
check(function('embedding_engine_settings_create',[c.c_char_p]*4+[out])(str(cache/'embeddinggemma-2-740m.litertlm').encode(),b'cpu',b'cpu',b'cpu',c.byref(settings)))
for name,value in [('num_threads',2),('audio_num_threads',2),('max_input_length',2048),('vision_tokens_per_image',70)]:
    check(function('embedding_engine_settings_set_'+name,[pointer,c.c_int])(settings,value))
check(function('embedding_engine_create',[pointer,out])(settings,c.byref(engine)))
check(function('embedding_options_create',[out])(c.byref(options)))
create=function('input_data_create',[c.c_int,pointer,c.c_size_t,out])
compute=function('embedding_engine_compute_embedding',[pointer,c.POINTER(pointer),c.c_size_t,pointer,out])
size=function('embedding_response_get_size',[pointer,c.POINTER(c.c_size_t)])
values=function('embedding_response_get_values',[pointer,c.POINTER(c.POINTER(c.c_float))])
fixtures=root/'ports/windows/NativeTests/Fixtures'
for name,color in [('SyntheticRed.png',(255,0,0)),('SyntheticBlue.png',(0,0,255))]:
    Image.new('RGB',(224,224),color).save(fixtures/name)
samples=[]
for text,query,image,audio in [('Where can I get something to eat?',True,None,None),('The restaurant serves delicious meals.',False,None,None),('A compiler reports a syntax error.',False,None,None),('',False,'SyntheticRed.png',None),('',False,None,'SyntheticSpeech.wav')]:
    value=('task: search result | query: ' if query else 'title: none | text: ')+text
    data=value.encode();buffer=c.create_string_buffer(data);item=pointer();response=pointer()
    check(create(0,buffer,len(data),c.byref(item)))
    handles=[item]
    if image or audio:
        media=(fixtures/(image or audio)).read_bytes();media_buffer=c.create_string_buffer(media);media_item=pointer()
        check(create(1 if image else 3,media_buffer,len(media),c.byref(media_item)));handles.append(media_item)
    inputs=(pointer*len(handles))(*handles)
    check(compute(engine,inputs,len(handles),options,c.byref(response)))
    count=c.c_size_t();vector=c.POINTER(c.c_float)()
    check(size(response,c.byref(count)));check(values(response,c.byref(vector)))
    assert count.value==768
    samples.append({'text':text,'query':query,'image':image,'audio':audio,'vector':[vector[i] for i in range(count.value)]})
    lib.litert_lm_embedding_response_delete(response)
    for handle in handles:lib.litert_lm_input_data_delete(handle)
lib.litert_lm_embedding_options_delete(options);lib.litert_lm_embedding_engine_delete(engine);lib.litert_lm_embedding_engine_settings_delete(settings)
(root/'ports/windows/NativeTests/Fixtures/Gemma.json').write_text(json.dumps({'runtime':'LiteRT-LM 0.19.1 macOS ARM64','samples':samples},separators=(',',':'))+'\n')
print('Gemma official macOS CPU reference generated')
