#!/opt/homebrew/bin/python3.13
"""Disposable artifact policy tests; never compile, sign, launch or fetch anything."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

assert sys.version_info >= (3, 13)
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("audit", ROOT / "Scripts/audit-no-models.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class BundlePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = Path(self.temp.name).resolve() / "Fixture.app"
        self.put("Contents/Info.plist", plistlib.dumps({"CFBundleExecutable": "Cliphoard"}))
        self.put("Contents/MacOS/Cliphoard", bytes.fromhex("cffaedfe") + b"public synthetic executable")
        self.put("Contents/Resources/LICENSE", b"Public fixture text")
        audit.audit_bundle(self.app)  # The valid baseline must pass before any negative mutation.

    def tearDown(self):
        self.temp.cleanup()

    def put(self, relative, data):
        p = self.app / relative
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return p

    def test_runtime_and_text_resources_are_allowed(self):
        self.put("Contents/Frameworks/libCLiteRTLM_mac.dylib", bytes.fromhex("cafebabe") + b"fixture")
        self.put("Contents/Resources/ThirdPartyNotices/LiteRTLM-LICENSE.txt",
                 (ROOT / "Vendor/LiteRTLM/LICENSE").read_bytes())
        self.assertGreater(audit.audit_bundle(self.app)["filesChecked"], 2)

    def test_actual_hub_defaults_are_allowed_but_extra_weights_are_not(self):
        base = "Contents/Resources/swift-transformers_Hub.bundle/Contents/Resources/"
        for name in ("gpt2_tokenizer_config.json", "t5_tokenizer_config.json"):
            source = ROOT / ".build/checkouts/swift-transformers/Sources/Hub/FallbackConfigs" / name
            self.put(base + name, source.read_bytes())
        audit.audit_bundle(self.app)
        self.put(base + "model.safetensors", b"public fake weights")
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)

    def test_weights_and_archives_rejected_at_every_depth(self):
        for name in ["model.mlmodelc/weights/weight.bin", "MODEL.MLPACKAGE/data", "model.litertlm",
                     "model.safetensors", "weights.bin", "model.onnx", "model.gguf", "model.zip",
                     "nested/renamed-payload.dat", "other.bundle/Contents/Resources/model.bin"]:
            with self.subTest(name=name):
                p = self.put("Contents/Resources/" + name, b"public fake weights")
                with self.assertRaises(audit.PolicyError):
                    audit.audit_bundle(self.app)
                p.unlink()
                while p.parent != self.app / "Contents/Resources":
                    p = p.parent
                    p.rmdir()

    def test_binary_cannot_hide_as_notice(self):
        self.put("Contents/Resources/ThirdPartyNotices/LiteRTLM-LICENSE.txt", b"weights\x00payload")
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)

    def test_oversized_text_rejected_before_read(self):
        p = self.put("Contents/Resources/ThirdPartyNotices/LiteRTLM-LICENSE.txt", b"")
        with p.open("wb") as f:
            f.truncate(1_048_577)
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)

    def test_symlink_does_not_escape_or_hide_model(self):
        external = Path(self.temp.name) / "outside"
        external.write_bytes(b"public canary")
        (self.app / "Contents/Resources/linked").symlink_to(external)
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)
        self.assertEqual(external.read_bytes(), b"public canary")

    def test_unsealed_root_and_empty_model_directory_rejected(self):
        for path in ["extra", "Contents/Resources/model.mlmodelc"]:
            p = self.app / path
            p.mkdir()
            with self.assertRaises(audit.PolicyError):
                audit.audit_bundle(self.app)
            p.rmdir()

    def test_legacy_override_refused_before_build(self):
        for key in ["BUNDLE_MODELS", "MAS_BUNDLE_MODELS", "MAS_MEDIA_MODEL", "CLIPHOARD_MEDIA_MODEL"]:
            with self.subTest(key=key):
                with self.assertRaises(audit.PolicyError):
                    audit.check_environment({key: "public-fixture"})
        audit.check_environment({"BUNDLE_MODELS": ""})

    def test_entrypoints_gate_before_build_and_sign(self):
        for name in ["build-app.sh", "build-mas.sh"]:
            source = (ROOT / "Scripts" / name).read_text()
            self.assertLess(source.index("--check-environment"), source.index("swift build"))
            self.assertLess(source.index('audit-no-models.py" "$APP"'), source.index("codesign --"))
            self.assertNotIn("coremlcompiler", source)
            self.assertNotIn("embed-media-model.sh", source)
        for name in ["release.sh", "deploy-local.sh"]:
            source = (ROOT / "Scripts" / name).read_text()
            self.assertNotIn("restore-models.sh", source)
            self.assertNotIn('BUNDLE_MODELS="', source)

    def test_actual_entrypoints_refuse_legacy_override_before_any_action(self):
        for name in ["build-app.sh", "build-mas.sh", "release.sh", "deploy-local.sh"]:
            with self.subTest(name=name):
                result = subprocess.run(
                    ["/bin/bash", str(ROOT / "Scripts" / name)], cwd=self.temp.name,
                    env={"PATH": "/usr/bin:/bin", "BUNDLE_MODELS": "public-fake-model",
                         "CLIPHOARD_PYTHON": sys.executable},
                    capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"BUNDLE_MODELS is retired", result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_legacy_embedder_fails_without_writing(self):
        before = sorted(str(p.relative_to(self.app)) for p in self.app.rglob("*"))
        result = subprocess.run(["/bin/bash", str(ROOT / "Scripts/embed-media-model.sh"),
                                 str(self.app), "/nonexistent/public-model"], capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, sorted(str(p.relative_to(self.app)) for p in self.app.rglob("*")))

    def test_weights_cannot_hide_in_notice_json(self):
        self.put("Contents/Resources/ThirdPartyNotices/weights.json", b'{"weights":[0.2,0.3,0.4]}')
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)

    def test_hub_known_name_cannot_carry_weights(self):
        self.put("Contents/Resources/swift-transformers_Hub.bundle/Contents/Resources/t5_tokenizer_config.json",
                 b'{"tokenizer_class":"T5Tokenizer","vocab":{"secret":1},"weights":[0.2,0.3]}')
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)

    def test_pinned_runtime_notices_and_hub_metadata(self):
        vendor = ROOT / "Vendor/LiteRTLM"
        self.put("Contents/Resources/ThirdPartyNotices/LiteRTLM-LICENSE.txt", (vendor / "LICENSE").read_bytes())
        for source in (vendor / "Notices").iterdir():
            if source.is_file():
                self.put("Contents/Resources/ThirdPartyNotices/LiteRTLM/" + source.name, source.read_bytes())
        info = {"CFBundleIdentifier": "swift-transformers.Hub.resources", "CFBundlePackageType": "BNDL",
                "CFBundleSupportedPlatforms": ["MacOSX"], "DTXcode": "2710"}
        name = "Contents/Resources/swift-transformers_Hub.bundle/Contents/Info.plist"
        self.put(name, plistlib.dumps(info))
        audit.audit_bundle(self.app)
        info["weights"] = [0.2, 0.3]
        self.put(name, plistlib.dumps(info))
        with self.assertRaises(audit.PolicyError):
            audit.audit_bundle(self.app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
