#!/usr/bin/env python3.14
"""CI-local CoreML ownership backport and shared bounded child runner.

Invoke with an explicit Python 3.14+ executable. Setup deliberately uses a pinned
CPython 3.13 conversion exception; no app build or published wheel is produced.
"""
import argparse
import base64
import csv
import email.parser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
PTH = '2638ce9e2500e572a5e0de7faed6661eb569d1b696fcba07b0dd223da5f5d224'

class Refused(RuntimeError): pass

def require(ok, reason):
    if not ok: raise Refused(reason)

def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

def metadata(path):
    st=path.lstat();require(stat.S_ISREG(st.st_mode),'nonregular file')
    return dict(sha256=sha(path),bytes=st.st_size,mode=stat.S_IMODE(st.st_mode))

def save(path,value):
    with path.open('x') as f:json.dump(value,f,indent=2,sort_keys=True);f.write('\n')

def present(pid):
    try:os.killpg(pid,0);return True
    except ProcessLookupError:return False

def environment(root):
    env={k:os.environ[k] for k in ('HOME','LANG','LC_ALL','DEVELOPER_DIR','MODELS') if k in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',TMPDIR=str(root/'tmp'),PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1',PIP_CONFIG_FILE='/dev/null',SETUPTOOLS_USE_DISTUTILS='stdlib',HF_HOME=str(root/'hf-cache'),HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',OMP_NUM_THREADS='2',OPENBLAS_NUM_THREADS='2',VECLIB_MAXIMUM_THREADS='2')
    return env

class Runner:
    """One deadline and one owned process group; normal signals defer at spawn."""
    def __init__(self,root,seconds):
        require(root.is_absolute() and root.resolve()==root,'absolute task directory required')
        require(not root.exists(),'task directory already exists')
        require(0<seconds<=1800,'invalid time budget')
        root.mkdir(parents=False,mode=0o700);(root/'tmp').mkdir(mode=0o700)
        self.root=root;self.started=time.monotonic();self.deadline=self.started+seconds
        self.child=None;self.absent=False;self.spawning=False;self.cancelled=False;self.commands=[];self.handlers={}
        self.env=environment(root)
    def remaining(self):
        require(not self.cancelled,'cancelled');left=self.deadline-time.monotonic();require(left>0,'shared deadline');return left
    def __enter__(self):
        def stop(*_):
            self.cancelled=True
            if not self.spawning:raise Refused('cancelled or deadline')
        for sig in (signal.SIGALRM,signal.SIGINT,signal.SIGTERM,signal.SIGHUP):self.handlers[sig]=signal.signal(sig,stop)
        signal.setitimer(signal.ITIMER_REAL,self.remaining());return self
    def command(self,name,argv,seconds=None,cwd=None):
        require(self.child is None,'unreconciled prior process');self.remaining()
        require(Path(argv[0]).is_absolute(),'explicit executable required')
        deadline=min(self.deadline,time.monotonic()+(seconds or self.remaining()))
        save(self.root/(name+'-intent.json'),{'argv':argv,'phaseSeconds':seconds})
        stdout=self.root/(name+'.stdout');stderr=self.root/(name+'.stderr')
        with stdout.open('xb') as out,stderr.open('xb') as err:
            self.spawning=True
            try:
                self.child=subprocess.Popen(argv,cwd=cwd or self.root,env=self.env,stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True);self.absent=False
            finally:self.spawning=False
            self.remaining()
            while self.child.poll() is None:
                require(time.monotonic()<deadline,'phase deadline');self.remaining()
                require(stdout.stat().st_size<=4*1024**2 and stderr.stat().st_size<=4*1024**2,'phase log cap')
                time.sleep(min(.05,max(0,deadline-time.monotonic())))
            self.remaining();require(time.monotonic()<deadline,'late phase completion')
            self.absent=not present(self.child.pid);code=self.child.returncode
            require(stdout.stat().st_size<=4*1024**2 and stderr.stat().st_size<=4*1024**2,'phase log cap')
            self.commands.append(dict(phase=name,exitCode=code,groupGone=self.absent))
            require(code==0 and self.absent,'child failed or group remains');self.child=None
        return stdout
    def cleanup(self):
        if self.child is None:return True
        end=time.monotonic()+2
        for sig,delay in ((signal.SIGTERM,.5),(signal.SIGKILL,1.5)):
            self.child.poll()
            if not self.absent:self.absent=not present(self.child.pid)
            if self.absent:return self.child.returncode is not None
            if time.monotonic()<end:
                try:os.killpg(self.child.pid,sig)
                except ProcessLookupError:self.absent=True
            until=min(end,time.monotonic()+delay)
            while time.monotonic()<until:
                self.child.poll()
                if not self.absent:self.absent=not present(self.child.pid)
                if self.absent and self.child.returncode is not None:return True
                time.sleep(.01)
        return self.absent and self.child.returncode is not None
    def __exit__(self,kind,value,tb):
        signal.setitimer(signal.ITIMER_REAL,0)
        for sig in self.handlers:signal.signal(sig,signal.SIG_IGN)
        end=time.monotonic()+3;signal.signal(signal.SIGALRM,lambda *_:os._exit(124));signal.setitimer(signal.ITIMER_REAL,3)
        clean=False
        try:
            try:clean=self.cleanup()
            except BaseException:pass
            result={'success':kind is None and clean,'failure':None if kind is None else kind.__name__,'cleanupConfirmed':clean,'commands':self.commands,'seconds':round(time.monotonic()-self.started,3)}
            signal.setitimer(signal.ITIMER_REAL,max(.001,min(1,end-time.monotonic())));save(self.root/'RESULT.json',result)
        finally:
            signal.setitimer(signal.ITIMER_REAL,0)
            for sig,handler in self.handlers.items():signal.signal(sig,handler)
        if kind is None:require(clean,'cleanup unconfirmed')
        return False

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):raise Refused('redirect refused')

def download(item,path,run):
    url=urllib.parse.urlsplit(item['url']);require(url.scheme=='https' and url.netloc in ('codeload.github.com','files.pythonhosted.org') and not url.query and not url.fragment,'unapproved URL')
    size=item.get('bytes',item.get('size'));require(type(size) is int and 0<size<256*1024**2,'download bound')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect());total=0;digest=hashlib.sha256();deadline=time.monotonic()+min(30,run.remaining())
    with opener.open(item['url'],timeout=min(20,run.remaining())) as response,path.open('xb') as out:
        require(response.status==200 and response.geturl()==item['url'],'download identity')
        while chunk:=response.read(1024**2):
            run.remaining();require(time.monotonic()<deadline,'download deadline');total+=len(chunk);require(total<=size,'download size');digest.update(chunk);out.write(chunk)
    require(total==size and digest.hexdigest()==item['sha256'],'download hash')

def extract_source(archive,target,source,run):
    target.mkdir();count=0;total=0;names=set()
    with tarfile.open(archive,'r:gz') as tar:
        for member in tar:
            run.remaining();parts=PurePosixPath(member.name).parts
            require(parts and parts[0]==source['prefix'] and '..' not in parts and not PurePosixPath(member.name).is_absolute(),'archive path')
            rel=Path(*parts[1:]);require(str(rel).casefold() not in names,'duplicate archive path');names.add(str(rel).casefold())
            path=target/rel;require(member.isdir() or member.isfile(),'archive special file')
            if member.isdir():path.mkdir(parents=True,exist_ok=True);continue
            count+=1;total+=member.size;require(count<=source['fileCount'] and total<=source['expandedBytes'],'source archive expansion')
            path.parent.mkdir(parents=True,exist_ok=True)
            with tar.extractfile(member) as inp,path.open('xb') as out:shutil.copyfileobj(inp,out)
            path.chmod(0o755 if member.mode&0o111 else 0o644)
    require(count==source['fileCount'] and total==source['expandedBytes'],'source inventory')

def inventory(root,run):
    files={};total=0
    for directory,dirs,names in os.walk(root,followlinks=False):
        for name in dirs:require(not (Path(directory)/name).is_symlink(),'symlink directory')
        for name in names:
            run.remaining();path=Path(directory)/name;item=metadata(path);total+=item['bytes'];require(total<2*1024**3 and len(files)<100000,'inventory limit');files[str(path.relative_to(root))]=item
    return files

def inspect_wheel(path,run):
    names=set();expanded=0
    with zipfile.ZipFile(path) as wheel:
        for m in wheel.infolist():
            run.remaining();p=PurePosixPath(m.filename);require(not p.is_absolute() and '..' not in p.parts and '\\' not in m.filename,'wheel path')
            require(m.filename.casefold() not in names,'wheel duplicate');names.add(m.filename.casefold());require(stat.S_IFMT(m.external_attr>>16) in (0,stat.S_IFREG,stat.S_IFDIR) and not m.flag_bits&1,'wheel special file')
            expanded+=m.file_size;require(expanded<1024**3 and len(names)<50000,'wheel expansion')
            if m.filename.endswith('.pth') or p.name in ('sitecustomize.py','usercustomize.py'):
                require(path.name=='setuptools-84.2.1-py3-none-any.whl' and m.filename=='distutils-precedence.pth' and m.file_size<1024 and hashlib.sha256(wheel.read(m)).hexdigest()==PTH,'unexpected startup hook')
    return expanded

def validate_records(site,venv,expected,run):
    versions={};seen_files=set();count=0
    for dist in sorted(site.glob('*.dist-info')):
        run.remaining();msg=email.parser.BytesParser().parsebytes((dist/'METADATA').read_bytes());name=msg['Name'].lower().replace('_','-');require(name not in versions,'duplicate distribution');versions[name]=msg['Version']
        record=dist/'RECORD';relative=str(record.relative_to(site));seen=set()
        for row in csv.reader(record.read_text().splitlines()):
            run.remaining();require(len(row)==3,'RECORD row');name,encoded,size=row;require(name not in seen and name and not PurePosixPath(name).is_absolute(),'RECORD path');seen.add(name)
            path=site/name;require(path.resolve().is_relative_to(venv),'RECORD escape');item=metadata(path);seen_files.add(str(path.resolve()))
            if name==relative:require(encoded==size=='','RECORD self hash');continue
            require(encoded.startswith('sha256=') and size.isdecimal(),'RECORD encoding')
            actual=base64.urlsafe_b64encode(bytes.fromhex(item['sha256'])).decode().rstrip('=');require(encoded=='sha256='+actual and int(size)==item['bytes'],'RECORD mismatch');count+=1
    require(versions==expected,'installed versions');require(all(str((site/name).resolve()) in seen_files for name in inventory(site,run)),'unrecorded site file');return {'versions':versions,'verifiedFiles':count}

def replace_native(site,artifact,run):
    target=site/'coremltools/libcoremlpython.so';record=site/'coremltools-9.0.dist-info/RECORD';before=metadata(target);old=record.read_bytes();rows=list(csv.reader(old.decode().splitlines()));matches=[i for i,r in enumerate(rows) if r[0]=='coremltools/libcoremlpython.so'];require(len(matches)==1,'native RECORD identity')
    shutil.copyfile(artifact,target);target.chmod(before['mode']);after=metadata(target);require(after['sha256']==sha(artifact),'native copy')
    original_row=rows[matches[0]][:];rows[matches[0]]=[original_row[0],'sha256='+base64.urlsafe_b64encode(bytes.fromhex(after['sha256'])).decode().rstrip('='),str(after['bytes'])]
    (run.root/'original-coreml-RECORD.csv').write_bytes(old)
    with record.open('w',newline='') as f:csv.writer(f).writerows(rows)
    return {'originalNative':before,'patchedNative':after,'originalRecordSHA256':hashlib.sha256(old).hexdigest(),'patchedRecordSHA256':sha(record),'originalRow':original_row,'qualification':'CI-local custom native backport; modified installed RECORD is not an official PyPI artifact.'}

def verify_native_linkage(install_id,linked):
    expected='@rpath/libcoremlpython.dylib'
    identity=install_id.splitlines();rows=linked.splitlines()
    require(len(identity)==2 and identity[1].strip()==expected,'native install ID')
    dependencies=[line.strip().split(' (',1)[0] for line in rows[1:]]
    require(len(dependencies)>1 and dependencies[0]==expected,'native self identity')
    require(all(path.startswith(('/System/Library/','/usr/lib/')) for path in dependencies[1:]),'unexpected native dependency')

def verify_copied_runtime(python,base,base_pin):
    require(python.resolve()==python and metadata(python)==base_pin and metadata(base)==base_pin,
            'copied Python drift')

def setup(args,run):
    lock=json.loads((HERE/'coreml-backport-lock.json').read_text());require(lock['schema']==1 and len(lock['packages'])==47,'lock shape')
    for name,digest in lock['localFiles'].items():require(sha(HERE/name)==digest,'checked-in source pin')
    expected={n:p['version'] for n,p in lock['packages'].items()};requirements=''.join(f"{n}=={p['version']} --hash=sha256:{p['wheel']['sha256']}\n" for n,p in lock['packages'].items());require((HERE/'conversion-requirements.lock').read_text()==requirements,'requirements parity')
    base=Path(args.python313).resolve();require(base.is_file(),'base interpreter');base_pin=metadata(base)
    info_code='import sys,sysconfig,platform,json; print(json.dumps(dict(version=platform.python_version(),machine=platform.machine(),include=sysconfig.get_path("include"),soabi=sysconfig.get_config_var("SOABI"))))'
    info=json.loads(run.command('base-identity',[str(base),'-I','-B','-c',info_code]).read_text());require(info['version']==lock['pythonVersion'] and info['machine']=='arm64' and info['soabi'].startswith('cpython-313'),'Python ABI')
    include=Path(info['include']);require((include/'Python.h').is_file(),'Python headers');header_files=inventory(include,run)
    tools={k:metadata(Path(getattr(args,k)).resolve()) for k in ('cmake','ninja','cc','cxx')};sdk=Path(args.sdk).resolve();require(sdk.is_dir() and (sdk/'SDKSettings.json').is_file(),'SDK identity')
    cmake_version=run.command('cmake-version',[args.cmake,'--version']).read_text().splitlines()[0]
    ninja_version=run.command('ninja-version',[args.ninja,'--version']).read_text().strip()
    compiler_version=run.command('compiler-version',[args.cxx,'--version']).read_text()
    require(cmake_version=='cmake version 4.4.4' and ninja_version=='1.13.2','admitted build tool versions')
    developer=Path('/Applications/Xcode_26.6.app/Contents/Developer')
    require(os.environ.get('DEVELOPER_DIR')==str(developer),'selected Xcode environment')
    require(all(Path(getattr(args,k)).resolve().is_relative_to(developer) for k in ('cc','cxx')) and sdk.is_relative_to(developer),'selected Xcode paths')
    xcode_version=run.command('xcode-version',['/usr/bin/xcodebuild','-version']).read_text().strip()
    require(xcode_version=='Xcode 26.6\nBuild version 17F113' and 'Apple clang version' in compiler_version,'selected Xcode compiler identity')
    require(json.loads((sdk/'SDKSettings.json').read_text()).get('Version')=='26.5','admitted SDK version')
    wheels=run.root/'wheels';wheels.mkdir();expanded=0
    for p in lock['packages'].values():
        w=p['wheel'];require(Path(w['filename']).name==w['filename'],'wheel filename');path=wheels/w['filename'];download(w,path,run);expanded+=inspect_wheel(path,run);require(expanded<2*1024**3,'total wheel expansion')
    archive=run.root/'source.tar.gz';download(lock['source'],archive,run);source=run.root/'source';extract_source(archive,source,lock['source'],run)
    fixed=source/lock['fix']['path'];require(sha(fixed)==lock['fix']['beforeSHA256'],'original native source');shutil.copyfile(HERE/'coreml-native/CoreMLPythonArray.mm',fixed);require(sha(fixed)==lock['fix']['afterSHA256'],'patched native source');shutil.copyfile(HERE/'coreml-native/CMakeLists.txt',source/'CMakeLists.txt')
    venv=run.root/'venv';run.command('create-venv',[str(base),'-I','-B','-m','venv','--without-pip','--copies',str(venv)],60);python=venv/'bin/python3.13'
    def runtime_pin():verify_copied_runtime(python,base,base_pin)
    runtime_pin();site=venv/'lib/python3.13/site-packages';require(site.is_dir() and not any(site.iterdir()),'fresh isolated site')
    parent=str(Path(sys.executable).resolve());run.command('install',[parent,'-I','-B','-m','pip','--python',str(python),'--isolated','--disable-pip-version-check','install','--no-index','--find-links',str(wheels),'--no-deps','--require-hashes','--no-compile','--no-cache-dir','-r',str(HERE/'conversion-requirements.lock')],180);runtime_pin()
    run.command('dependency-check',[parent,'-I','-B','-m','pip','--python',str(python),'--isolated','check'],60);runtime_pin()
    validate_records(site,venv,expected,run);before=inventory(site,run);numpy_include=site/'numpy/_core/include';numpy_headers=inventory(numpy_include,run)
    build=run.root/'native';configuration=[args.cmake,'-S',str(source),'-B',str(build),'-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=12.3','-DCMAKE_OSX_SYSROOT='+str(sdk),'-DCMAKE_C_COMPILER='+args.cc,'-DCMAKE_CXX_COMPILER='+args.cxx,'-DCMAKE_MAKE_PROGRAM='+args.ninja,'-DPYTHON_INCLUDE_DIRS='+str(include),'-DNUMPY_INCLUDE='+str(numpy_include),'-DOVERWRITE_PB_SOURCE=OFF','-Dprotobuf_BUILD_TESTS=OFF','-Dprotobuf_WITH_ZLIB=OFF']
    build_deadline=time.monotonic()+600;run.command('configure',configuration,min(120,build_deadline-time.monotonic()));run.command('build',[args.cmake,'--build',str(build),'--target','coremlpython','--parallel','2'],build_deadline-time.monotonic())
    artifact=source/'coremltools/libcoremlpython.so';require(100000<metadata(artifact)['bytes']<100*1024**2,'native artifact size')
    arch=run.command('native-arch',['/usr/bin/lipo','-archs',str(artifact)],30).read_text().strip();require(arch=='arm64','native architecture')
    install_id=run.command('native-install-id',['/usr/bin/otool','-D',str(artifact)],30).read_text()
    linkage=run.command('native-linkage',['/usr/bin/otool','-L',str(artifact)],30).read_text()
    verify_native_linkage(install_id,linkage)
    run.command('native-uuid',['/usr/bin/dwarfdump','--uuid',str(artifact)],30)
    overlay=replace_native(site,artifact,run);after=inventory(site,run);changed=sorted(n for n in set(before)|set(after) if before.get(n)!=after.get(n));require(changed==['coremltools-9.0.dist-info/RECORD','coremltools/libcoremlpython.so'],'unexpected overlay change')
    records=validate_records(site,venv,expected,run);runtime_pin();require(inventory(include,run)==header_files and inventory(numpy_include,run)==numpy_headers,'headers changed')
    run.remaining();save(run.root/'environment.json',{'schema':1,'qualification':lock['qualification'],'runtime':{'path':str(python),'metadata':metadata(python),**info},'source':lock['source'],'fix':lock['fix'],'lockSHA256':sha(HERE/'coreml-backport-lock.json'),'driverSHA256':sha(HERE/'coreml-native/CMakeLists.txt'),'toolchain':tools,'sdk':str(sdk),'sdkSettingsSHA256':sha(sdk/'SDKSettings.json'),'overlay':overlay,'sitePackagesRoot':str(site),'files':after,'recordVerification':records,'nativeImports':False,'modelExecution':False,'trustBoundary':'Existing Python/pip, host standard libraries, compiler runtime and full SDK are trusted host tooling; recorded hashes are not a hermetic toolchain.'});run.remaining()

def main():
    require(sys.version_info>=(3,14),'explicit Python 3.14+ required')
    parser=argparse.ArgumentParser();sub=parser.add_subparsers(dest='mode',required=True)
    p=sub.add_parser('setup')
    for name in ('python313','work-dir','cmake','ninja','cc','cxx','sdk'):p.add_argument('--'+name,required=True)
    p=sub.add_parser('run');p.add_argument('--seconds',type=int,required=True);p.add_argument('--log-dir',type=Path,required=True);p.add_argument('--model-python',type=Path);p.add_argument('--allow-model-downloads',action='store_true');p.add_argument('--cwd',type=Path);p.add_argument('command',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    if args.mode=='run':
        command=args.command[1:] if args.command[:1]==['--'] else args.command;require(bool(command),'command missing')
        with Runner(args.log_dir,args.seconds) as run:
            run.env.pop('SETUPTOOLS_USE_DISTUTILS',None)
            if args.model_python:
                require(args.model_python.is_absolute() and args.model_python.is_file(),'explicit model Python required')
                run.env['CLIPHOARD_MODEL_PYTHON']=str(args.model_python)
            if args.allow_model_downloads:
                require(args.model_python is not None,'model download runtime required')
                run.env.update(HF_HUB_OFFLINE='0',TRANSFORMERS_OFFLINE='0')
            cwd=args.cwd or Path.cwd()
            require(cwd.is_absolute() and cwd.is_dir(),'explicit existing cwd required')
            run.command('command',command,cwd=cwd)
    else:
        root=Path(args.work_dir);require(shutil.disk_usage(root.parent).free>=5*1024**3,'5 GiB free disk required')
        with Runner(root,1200) as run:setup(args,run)
    return 0
if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as exc:print(json.dumps({'status':'failed','type':type(exc).__name__,'reason':str(exc) if isinstance(exc,Refused) else 'unexpected error'}));raise SystemExit(1)
