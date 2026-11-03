#!/bin/bash
set -eu
umask 077
src="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$src/../.." && pwd)"
dest="$HOME/Library/Application Support/Cliphoard Agent"
runtime="${CLIPHOARD_PYTHON:-/opt/homebrew/bin/python3.13}"
"$runtime" -c 'import sys; assert sys.version_info >= (3, 13)'
mkdir -p "$dest"
"$runtime" -m venv "$dest/venv"
"$dest/venv/bin/python" -m pip install --disable-pip-version-check 'mcp==1.30.0'
swiftc -O "$root/Sources/Cliphoard/Support/HistoryArchive.swift" \
    "$root/Sources/Cliphoard/Search/Detectors.swift" "$root/Sources/Cliphoard/Clipboard/ClipItem.swift" \
    "$src/Reader.swift" "$src/main.swift" -o "$dest/venv/bin/cliphoard-agent-reader.new"
mv "$dest/venv/bin/cliphoard-agent-reader.new" "$dest/venv/bin/cliphoard-agent-reader"
install -m 600 "$src/server.py" "$dest/server.py"
