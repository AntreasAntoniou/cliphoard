#!/opt/homebrew/bin/python3.14
"""Bounded subprocess protocol smoke. Generated synthetic text only; Python3.14+."""
import json
import os
from pathlib import Path
import selectors
import queue
import threading
import struct
import subprocess
import sys
import time

assert sys.version_info >= (3, 14), "Python3.14+ required"
ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / ("engine/target/debug/cliphoard-engine.exe" if os.name == "nt" else "engine/target/debug/cliphoard-engine")
PREFIX = "[CLIPHOARD_SYNTHETIC_V1] "
checks = 0

def check(condition):
    global checks
    checks += 1
    assert condition, f"synthetic smoke check {checks}"

def encode(command, request_id=1, version=1):
    body = json.dumps({"version": version, "id": request_id, "command": command}).encode()
    return struct.pack("<I", len(body)) + body

def read_exact(process, count):
    if os.name == "nt":
        # Windows selectors support sockets, not anonymous subprocess pipes.
        completed = queue.Queue(maxsize=1)
        def read_pipe():
            try:
                output = bytearray()
                while len(output) < count:
                    chunk = os.read(process.stdout.fileno(), count-len(output))
                    if not chunk:
                        raise AssertionError("fixture response truncated")
                    output.extend(chunk)
                completed.put(bytes(output))
            except Exception as error:
                completed.put(error)
        threading.Thread(target=read_pipe, daemon=True).start()
        try:
            result = completed.get(timeout=3)
        except queue.Empty:
            raise AssertionError("fixture response deadline") from None
        if isinstance(result, Exception):
            raise result
        return result
    output = bytearray()
    deadline = time.monotonic() + 3
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while len(output) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise AssertionError("fixture response deadline")
            chunk = os.read(process.stdout.fileno(), count-len(output))
            if not chunk:
                raise AssertionError("fixture response truncated")
            output.extend(chunk)
    return bytes(output)

for args in [[], ["--windows-service"], ["--synthetic-stdio", "extra"]]:
    result = subprocess.run([ENGINE, *args], capture_output=True, timeout=3)
    check(result.returncode == 78 and result.stdout == b"")

process = subprocess.Popen([ENGINE, "--synthetic-stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
request_id = 0
try:
    def call(command):
        global request_id
        request_id += 1
        process.stdin.write(encode(command, request_id)); process.stdin.flush()
        count = struct.unpack("<I", read_exact(process,4))[0]
        check(0 < count <= 256 * 1024)
        response = json.loads(read_exact(process,count))
        check(response["version"] == 1 and response["id"] == request_id)
        return response
    check(call({"op":"hello"})["result"]["mode"] == "synthetic-only")
    first = call({"op":"captureSyntheticText","text":PREFIX+"smoke café"})["result"]["item"]
    duplicate = call({"op":"captureSyntheticText","text":PREFIX+"smoke café"})["result"]["item"]
    check(first["id"] == duplicate["id"])
    check(call({"op":"pin","itemId":first["id"],"pinned":True})["result"]["item"]["pinned"])
    check(len(call({"op":"search","query":"CAFÉ","limit":2})["result"]["items"]) == 1)
    check(call({"op":"select","itemId":first["id"]})["result"]["text"] == PREFIX+"smoke café")
    check(call({"op":"clearSynthetic"})["result"]["removed"] == 1)
    for i in range(20):
        prefix = PREFIX + f"{i:04}"
        call({"op":"captureSyntheticText","text":prefix+"\x01"*(8192-len(prefix))})
    check(0 < len(call({"op":"list","limit":20})["result"]["items"]) < 20)
    check(0 < len(call({"op":"search","query":"","limit":20})["result"]["items"]) < 20)
    check(call({"op":"status"})["result"]["count"] == 20)
    check(call({"op":"lock"})["result"]["locked"])
    check(call({"op":"list","limit":1})["error"] == "locked")
    check(call({"op":"status"})["result"]["count"] == 0)
    process.stdin.close(); process.wait(timeout=3)
    check(process.returncode == 0)
finally:
    if process.poll() is None:
        process.kill(); process.wait(timeout=3)
    process.stdout.close(); process.stderr.close()

for payload in [struct.pack("<I",0), struct.pack("<I",256*1024+1), b"\x01", struct.pack("<I",2)+b"x"]:
    result = subprocess.run([ENGINE,"--synthetic-stdio"],input=payload,capture_output=True,timeout=3)
    check(result.returncode == 65 and result.stdout == b"")
print(json.dumps({"status":"passed","synthetic_checks":checks,"python":sys.version.split()[0],"production_transport":"refused"}))
