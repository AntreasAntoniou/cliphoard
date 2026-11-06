"""Install one hash-pinned CMake wheel into a fresh CI-only Python3.14 environment."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bounded_ci_helpers', HERE/'coreml_backport.py')
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)

WHEEL = {
    'name': 'cmake-4.4.4-py3-none-macosx_10_10_universal2.whl',
    'url': 'https://files.pythonhosted.org/packages/3f/02/86b484e16c91de4bdf90dfab37a33c3e5512bc30d3a494759976df0943b9/cmake-4.4.4-py3-none-macosx_10_10_universal2.whl',
    'bytes': 54404900,
    'sha256': '883962a72b1b3a16ff445427f24c8caca9797dd9e563bbe208cbcd89e877f9d3',
}


def provision(run):
    wheel = run.root/WHEEL['name']
    bounded.download(WHEEL, wheel, run)
    expanded = bounded.inspect_wheel(wheel, run)
    venv = run.root/'venv'
    run.command('venv', [sys.executable, '-I', '-B', '-m', 'venv', '--copies', '--without-pip', str(venv)], 40)
    python = venv/'bin/python3.14'
    run.command('install', [sys.executable, '-I', '-B', '-m', 'pip', '--isolated', '--python', str(python),
                           'install', '--no-index', '--no-deps', '--no-compile', '--no-cache-dir',
                           '--disable-pip-version-check', str(wheel)], 60)
    site = venv/'lib/python3.14/site-packages'
    records = bounded.validate_records(site, venv, {'cmake': '4.4.4'}, run)
    binary = site/'cmake/data/bin/cmake'
    bounded.require(binary.resolve() == binary and binary.is_file(), 'native CMake path')
    version = run.command('version', [str(binary), '--version'], 10).read_text().splitlines()[0]
    bounded.require(version == 'cmake version 4.4.4', 'pinned CMake version mismatch: ' + version)
    bounded.save(run.root/'PROVENANCE.json', {'wheel': WHEEL, 'wheelExpandedBytes': expanded,
                  'records': records, 'cmake': {'path': str(binary), **bounded.metadata(binary)},
                  'version': version, 'python': sys.version, 'scope': 'CI tool only; no app or model artifact'})
    return binary


def main():
    bounded.require(sys.version_info[:3] == (3, 14, 6), 'explicit orchestration Python3.14.6 required')
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    with bounded.Runner(args.work_dir, 180) as run:
        binary = provision(run)
    # Publish only after cleanup and successful result writing, never on partial install.
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        output.write('cmake=' + str(binary) + '\n')


if __name__ == '__main__':
    main()
