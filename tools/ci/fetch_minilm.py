"""Fetch only reviewed immutable MiniLM data for CI; never execute repository code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = "sentence-transformers/all-MiniLM-L6-v2"
REVISION = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
FILES = {
    "1_Pooling/config.json", "config.json", "config_sentence_transformers.json",
    "model.safetensors", "modules.json", "sentence_bert_config.json",
    "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.txt",
}
MAX_BYTES = 100 * 1024 * 1024
SECONDS = 300


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_manifest_key")
        result[key] = value
    return result


def read_manifest(path):
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    if data.get("repo") != REPO or data.get("revision") != REVISION:
        raise ValueError("unexpected_model_identity")
    if set(data.get("files", {})) != FILES:
        raise ValueError("unexpected_model_files")
    for item in data["files"].values():
        if (type(item.get("bytes")) is not int or not 0 < item["bytes"] <= MAX_BYTES
                or not isinstance(item.get("sha256"), str)
                or re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is None):
            raise ValueError("invalid_file_pin")
    if sum(item["bytes"] for item in data["files"].values()) > MAX_BYTES:
        raise ValueError("model_size_bound")
    return data


def allowed_url(url):
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    return (parsed.scheme == "https" and parsed.username is None
            and parsed.password is None and parsed.port in (None, 443)
            and (host == "huggingface.co" or host.endswith(".huggingface.co")
                 or host == "hf.co" or host.endswith(".hf.co")))


class ModelRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed_url(newurl):
            raise ValueError("unapproved_model_redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def copy_verified(response, destination, expected, deadline):
    """Bound even a chunked/no-Content-Length response before accepting bytes."""
    if response.status != 200 or not allowed_url(response.geturl()):
        raise ValueError("unexpected_model_response")
    digest = hashlib.sha256()
    count = 0
    with destination.open("xb") as output:
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError("model_download_deadline")
            chunk = response.read(min(1024 * 1024, expected["bytes"] - count + 1))
            if not chunk:
                break
            count += len(chunk)
            if count > expected["bytes"]:
                raise ValueError("model_response_too_large")
            digest.update(chunk)
            output.write(chunk)
    if count != expected["bytes"] or digest.hexdigest() != expected["sha256"]:
        raise ValueError("model_response_pin_mismatch")


def main():
    if sys.version_info < (3, 14):
        raise RuntimeError("Python 3.14+ required")
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    manifest = read_manifest(args.manifest)
    started = time.monotonic()
    deadline = started + SECONDS
    if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0):
        raise RuntimeError("existing_alarm")

    def expired(_signum, _frame):
        raise TimeoutError("model_download_deadline")

    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, SECONDS)
    try:
        # Exclusive output is never reused, removed, or automatically retried.
        args.output.mkdir(mode=0o700)
        # No credential headers, cookies, proxy settings, or implicit HF login.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), ModelRedirects())
        for name, expected in sorted(manifest["files"].items()):
            target = args.output / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            url = f"https://huggingface.co/{REPO}/resolve/{REVISION}/{name}"
            request = urllib.request.Request(url, headers={"User-Agent": "Cliphoard-model-CI"})
            with opener.open(request, timeout=min(20, max(.001, deadline-time.monotonic()))) as response:
                copy_verified(response, target, expected, deadline)
        print(json.dumps({"status": "verified", "files": len(FILES),
                          "bytes": sum(x["bytes"] for x in manifest["files"].values()),
                          "manifestSHA256": hashlib.sha256(args.manifest.read_bytes()).hexdigest()}))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def failure_record(error):
    # A CDN redirect can contain a signed query. Never print its URL/body/reason.
    detail = {"status": "failed", "exceptionClass": type(error).__name__}
    if isinstance(error, urllib.error.HTTPError):
        detail["httpStatus"] = error.code
        error.close()
    return detail


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps(failure_record(error)), file=sys.stderr)
        raise SystemExit(1)
