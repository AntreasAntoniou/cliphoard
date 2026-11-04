#!/bin/bash
set -eu
umask 077
src="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$src/../.." && pwd)"
dest="$HOME/Library/Application Support/Cliphoard Agent"
runtime="${CLIPHOARD_PYTHON:-/opt/homebrew/bin/python3.14}"
replace="${1:-}"
if [ "$#" -gt 1 ] || { [ -n "$replace" ] && [ "$replace" != "--replace-environment" ]; }; then
    echo 'Usage: install.sh [--replace-environment]' >&2
    exit 1
fi
"$runtime" -c 'import sys; assert sys.version_info >= (3, 14)'
if { [ -e "$dest/venv" ] || [ -L "$dest/venv" ] || [ -e "$dest/server.py" ]; } && [ "$replace" != '--replace-environment' ]; then
    echo 'Stop/disconnect MCP clients, then rerun with --replace-environment. The old installation will be preserved.' >&2
    exit 1
fi
mkdir -p "$dest/environments"
# This is the permanent generation path: venv shebangs must never point to a renamed staging directory.
environment="$(mktemp -d "$dest/environments/python314.XXXXXXXX")"
"$runtime" -m venv "$environment"
"$environment/bin/python" -c 'import sys; assert sys.version_info >= (3, 14)'
"$environment/bin/python" -m pip install --disable-pip-version-check 'pip==26.3'
"$environment/bin/python" -m pip install --disable-pip-version-check 'mcp==1.30.0'
swiftc -O "$root/Sources/Cliphoard/Support/HistoryArchive.swift" \
    "$root/Sources/Cliphoard/Search/Detectors.swift" "$root/Sources/Cliphoard/Clipboard/ClipItem.swift" \
    "$src/Reader.swift" "$src/main.swift" -o "$environment/bin/cliphoard-agent-reader"
swiftc -O -parse-as-library "$root/Sources/Cliphoard/Support/AgentWriteProtocol.swift" \
    "$root/Sources/Cliphoard/Support/AgentWriteDirectory.swift" \
    "$src/WriterConnection.swift" "$src/WriterMain.swift" -o "$environment/bin/cliphoard-agent-writer"
install -m 600 "$src/server.py" "$environment/server.py"
if [ -n "$replace" ]; then
    "$runtime" "$src/install_environment.py" "$dest" "$environment" "$replace"
else
    "$runtime" "$src/install_environment.py" "$dest" "$environment"
fi
