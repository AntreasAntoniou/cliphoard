import test from "node:test";
import assert from "node:assert/strict";
import { readFile, writeFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { signLicence } from "../src/licence.mjs";
import { syntheticKeys } from "./fixtures.mjs";

test("actual direct Licence.swift verifies Worker key; CryptoKit raw seed has the same public key", { timeout: 60000 }, async () => {
  const keys = await syntheticKeys();
  const order = { mode: "test", storeId: "123", orderId: "1001", issued: 1767323045 };
  const licence = await signLicence(order, keys.seed, keys.publicHex);
  const source = await readFile(new URL("../../Sources/Cliphoard/Support/Licence.swift", import.meta.url), "utf8");
  const declaration = /static let publicKey: \[UInt8\] = \[[^\]]+\]/g;
  assert.equal([...source.matchAll(declaration)].length, 1, "exact one fixture seam; app source unchanged");
  const fixture = source.replace(declaration, "static var publicKey: [UInt8] { testPublicKey }");
  const harness = `
struct Input: Decodable { let seed: String; let publicHex: String; let licence: String; let orderID: String; let issued: Double }
let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
let hex = Array(input.publicHex)
let testPublicKey: [UInt8] = stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0+1]), radix:16)! }
guard case .pro(let orderID, let issued) = Licence.verify(input.licence),
      orderID == input.orderID, issued.timeIntervalSince1970 == input.issued else { exit(1) }
let segments = input.licence.dropFirst(6).split(separator: ".")
func decode(_ value: Substring) -> Data {
  var s = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  while s.count % 4 != 0 { s += "=" }; return Data(base64Encoded:s)!
}
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(base64Encoded:input.seed)!)
guard Array(privateKey.publicKey.rawRepresentation) == testPublicKey else { exit(2) }
let cryptoKitSignature = try privateKey.signature(for:decode(segments[0]))
guard privateKey.publicKey.isValidSignature(cryptoKitSignature, for:decode(segments[0])) else { exit(4) }
var tampered = Array(input.licence)
tampered[10] = tampered[10] == "A" ? "B" : "A"
guard !Licence.verify(String(tampered)).isPro, !Licence.verify("not-a-key").isPro else { exit(3) }
print("PASS: actual verifier, raw-seed public-key parity, valid CryptoKit signature, tamper rejection")
`;
  const base = new URL("../.test-tmp/", import.meta.url);
  await mkdir(base, { recursive: true, mode: 0o700 });
  const dir = await mkdtemp(fileURLToPath(new URL("interop-", base)));
  try {
    const path = dir + "/main.swift";
    await writeFile(path, fixture + harness, { mode: 0o600 });
    const result = spawnSync("/usr/bin/swift", [path], {
      input: JSON.stringify({ ...keys, licence, orderID: "ls:test:123:1001", issued: order.issued }),
      encoding: "utf8", timeout: 50000, maxBuffer: 100000,
    });
    // Do not copy arbitrary process diagnostics (or fixture data) into evidence.
    assert.equal(result.status, 0, "Swift interop process must succeed");
    assert.match(result.stdout, /^PASS: actual verifier/);
    process.stdout.write(`Source verifier SHA256: ${createHash("sha256").update(source).digest("hex")}\n`);
  } finally { await rm(dir, { recursive: true }); }
});
