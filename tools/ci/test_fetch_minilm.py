"""Offline downloader rejection tests; no network or pretrained model execution."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import time
import unittest
import urllib.error

import fetch_minilm as fetch


class Response(io.BytesIO):
    status = 200
    def geturl(self):
        return "https://cas-bridge.xethub.hf.co/model"


class FetchTests(unittest.TestCase):
    def test_exact_download_and_content_rejections(self):
        wanted = {"bytes": 3, "sha256": hashlib.sha256(b"abc").hexdigest()}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "valid"
            fetch.copy_verified(Response(b"abc"), target, wanted, time.monotonic()+2)
            self.assertEqual(target.read_bytes(), b"abc")
            for name, body in [("large", b"abcd"), ("short", b"ab"), ("changed", b"xyz")]:
                with self.subTest(name=name), self.assertRaises(ValueError):
                    fetch.copy_verified(Response(body), root/name, wanted, time.monotonic()+2)
            with self.assertRaises(TimeoutError):
                fetch.copy_verified(Response(b"abc"), root/"expired", wanted, 0)
            with self.assertRaises(FileExistsError):
                fetch.copy_verified(Response(b"abc"), target, wanted, time.monotonic()+2)

    def test_manifest_rejects_unpinned_or_extra_input(self):
        original = json.loads(Path(__file__).with_name("minilm-inputs.json").read_text())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/"manifest.json"
            for change in ("revision", "file", "hash", "size", "boolean"):
                data = json.loads(json.dumps(original))
                if change == "revision": data["revision"] = "main"
                if change == "file": data["files"]["model.py"] = {"sha256": "0"*64,"bytes": 1}
                if change == "hash": data["files"]["model.safetensors"]["sha256"] = "invalid"
                if change == "size": data["files"]["model.safetensors"]["bytes"] = fetch.MAX_BYTES+1
                if change == "boolean": data["files"]["model.safetensors"]["bytes"] = True
                path.write_text(json.dumps(data))
                with self.subTest(change=change), self.assertRaises(ValueError):
                    fetch.read_manifest(path)
            path.write_text('{"repo":"one","repo":"two"}')
            with self.assertRaises(ValueError): fetch.read_manifest(path)

    def test_redirects_and_error_output(self):
        self.assertTrue(fetch.allowed_url("https://huggingface.co/repo"))
        self.assertTrue(fetch.allowed_url("https://cas-bridge.xethub.hf.co/data?signature=private"))
        for url in ("http://huggingface.co/x", "https://127.0.0.1/x", "https://huggingface.co.evil/x",
                    "https://user:password@huggingface.co/x", "https://huggingface.co:8443/x"):
            self.assertFalse(fetch.allowed_url(url), url)
            with self.assertRaises(ValueError):
                fetch.ModelRedirects().redirect_request(None, None, 302, "redirect", {}, url)
        error = urllib.error.HTTPError("https://huggingface.co/?token=CANARY", 403,
                                       "CANARY", {}, io.BytesIO(b"CANARY"))
        self.assertEqual(fetch.failure_record(error),
                         {"status":"failed", "exceptionClass":"HTTPError", "httpStatus":403})
        self.assertNotIn("CANARY", json.dumps(fetch.failure_record(ValueError("CANARY"))))


if __name__ == "__main__":
    unittest.main()
