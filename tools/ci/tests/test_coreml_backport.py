"""Pure file fixtures and fake child ownership; no downloads/install/native code."""
import base64
import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SOURCE=Path(__file__).resolve().parents[1]/'coreml_backport.py'
spec=importlib.util.spec_from_file_location('backport',SOURCE)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class NoCommands:
    def __init__(self,root):self.root=root
    def remaining(self):return 100

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name).resolve();self.run=NoCommands(self.root)
    def tearDown(self):self.tmp.cleanup()
    def test_native_install_id_is_not_dependency(self):
        identity='/artifact:\n@rpath/libcoremlpython.dylib\n'
        linked='/artifact:\n\t@rpath/libcoremlpython.dylib (compatibility version 0.0.0, current version 0.0.0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
        m.verify_native_linkage(identity,linked)
        with self.assertRaises(m.Refused):m.verify_native_linkage(identity,linked+'\t@rpath/untrusted.dylib (compatibility version 0.0.0)\n')
        with self.assertRaises(m.Refused):m.verify_native_linkage(identity.replace('libcoremlpython','other'),linked)
        with self.assertRaises(m.Refused):m.verify_native_linkage(identity,linked.replace('/usr/lib/','/tmp/'))
    def test_lock_and_requirements(self):
        lock=json.loads((m.HERE/'coreml-backport-lock.json').read_text())
        self.assertEqual(len(lock['packages']),47)
        for name,digest in lock['localFiles'].items():self.assertEqual(m.sha(m.HERE/name),digest)
        expected=''.join(f"{n}=={p['version']} --hash=sha256:{p['wheel']['sha256']}\n" for n,p in lock['packages'].items())
        self.assertEqual((m.HERE/'conversion-requirements.lock').read_text(),expected)
        for item in lock['packages'].values():
            self.assertTrue(item['wheel']['filename'].endswith('.whl'))
            self.assertTrue(item['wheel']['url'].startswith('https://files.pythonhosted.org/'))
    def test_no_home_or_credentials(self):
        with patch.dict(os.environ,{'HOME':'/existing','HF_TOKEN':'secret','AWS_SECRET_ACCESS_KEY':'secret','HF_HUB_OFFLINE':'0'},clear=True):
            env=m.environment(self.root)
        self.assertEqual(env['HOME'],'/existing');self.assertEqual(env['HF_HUB_OFFLINE'],'1')
        self.assertNotIn('HF_TOKEN',env);self.assertNotIn('AWS_SECRET_ACCESS_KEY',env)
    def test_copied_runtime_pin(self):
        base=self.root/'base';copied=self.root/'python';base.write_bytes(b'executable');copied.write_bytes(base.read_bytes())
        pin=m.metadata(base);m.verify_copied_runtime(copied,base,pin)
        copied.write_bytes(b'changed')
        with self.assertRaises(m.Refused):m.verify_copied_runtime(copied,base,pin)
        copied.unlink();copied.symlink_to(base)
        with self.assertRaises(m.Refused):m.verify_copied_runtime(copied,base,pin)
    def test_safe_source(self):
        archive=self.root/'source.tar.gz'
        with tarfile.open(archive,'w:gz') as t:
            item=tarfile.TarInfo('prefix/file');item.size=3;t.addfile(item,io.BytesIO(b'abc'))
        m.extract_source(archive,self.root/'out',dict(prefix='prefix',fileCount=1,expandedBytes=3),self.run)
        self.assertEqual((self.root/'out/file').read_bytes(),b'abc')
    def test_source_traversal_and_symlink_rejected(self):
        for index,(name,kind) in enumerate((('prefix/../escape',tarfile.REGTYPE),('prefix/link',tarfile.SYMTYPE))):
            archive=self.root/f'{index}.tar.gz'
            with tarfile.open(archive,'w:gz') as t:
                item=tarfile.TarInfo(name);item.type=kind;item.linkname='/outside';t.addfile(item)
            with self.assertRaises(m.Refused):m.extract_source(archive,self.root/f'out{index}',dict(prefix='prefix',fileCount=1,expandedBytes=0),self.run)
    def test_wheel_hooks_and_paths(self):
        for index,name in enumerate(('pkg/a.py','../escape','hook.pth','sitecustomize.py')):
            wheel=self.root/f'{index}.whl'
            with zipfile.ZipFile(wheel,'w') as z:z.writestr(name,'pass')
            if index==0:self.assertEqual(m.inspect_wheel(wheel,self.run),4)
            else:
                with self.assertRaises(m.Refused):m.inspect_wheel(wheel,self.run)
    def record_fixture(self):
        site=self.root/'venv/lib/site-packages';dist=site/'coremltools-9.0.dist-info';dist.mkdir(parents=True)
        target=site/'coremltools/libcoremlpython.so';target.parent.mkdir();target.write_bytes(b'old')
        (dist/'METADATA').write_text('Name: coremltools\nVersion: 9.0\n')
        rows=[]
        for file in (target,dist/'METADATA'):
            rows.append([str(file.relative_to(site)),'sha256='+base64.urlsafe_b64encode(hashlib.sha256(file.read_bytes()).digest()).decode().rstrip('='),str(file.stat().st_size)])
        rows.append(['coremltools-9.0.dist-info/RECORD','',''])
        with (dist/'RECORD').open('w',newline='') as f:csv.writer(f).writerows(rows)
        return site,dist,target
    def test_overlay_single_record_change(self):
        site,dist,target=self.record_fixture();before=list(csv.reader((dist/'RECORD').read_text().splitlines()))
        m.validate_records(site,self.root/'venv',{'coremltools':'9.0'},self.run)
        artifact=self.root/'built.so';artifact.write_bytes(b'patched');proof=m.replace_native(site,artifact,self.run)
        after=list(csv.reader((dist/'RECORD').read_text().splitlines()))
        self.assertEqual(sum(a!=b for a,b in zip(before,after)),1)
        self.assertEqual(target.read_bytes(),b'patched');self.assertIn('custom',proof['qualification'])
        m.validate_records(site,self.root/'venv',{'coremltools':'9.0'},self.run)
    def test_record_tamper_and_escape(self):
        site,dist,target=self.record_fixture();target.write_bytes(b'bad')
        with self.assertRaises(m.Refused):m.validate_records(site,self.root/'venv',{'coremltools':'9.0'},self.run)
        (dist/'RECORD').write_text('../../../../outside,sha256=abc,1\n')
        with self.assertRaises(m.Refused):m.validate_records(site,self.root/'venv',{'coremltools':'9.0'},self.run)
    def test_fake_child_success_and_exclusive_output(self):
        class Fake:
            pid=123456;returncode=0
            def poll(self):return self.returncode
        out=self.root/'run'
        with patch.object(m.subprocess,'Popen',return_value=Fake()),patch.object(m,'present',return_value=False):
            with m.Runner(out,10) as run:run.command('fake',['/not-executed'])
        self.assertTrue(json.loads((out/'RESULT.json').read_text())['success'])
        with self.assertRaises(m.Refused):m.Runner(out,10)
    def test_cancel_during_spawn_owned_cleanup(self):
        class Fake:
            pid=123456;returncode=None
            def poll(self):return self.returncode
        child=Fake();alive=[True];signals=[]
        def spawn(*a,**kw):signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None);return child
        def kill(pid,sig):signals.append(sig);alive[0]=False;child.returncode=-15
        out=self.root/'cancel'
        with patch.object(m.subprocess,'Popen',side_effect=spawn),patch.object(m,'present',side_effect=lambda _:alive[0]),patch.object(m.os,'killpg',side_effect=kill):
            with self.assertRaises(m.Refused):
                with m.Runner(out,10) as run:run.command('fake',['/not-executed'])
        receipt=json.loads((out/'RESULT.json').read_text());self.assertFalse(receipt['success']);self.assertTrue(receipt['cleanupConfirmed']);self.assertEqual(signals,[signal.SIGTERM])

if __name__=='__main__':unittest.main()
