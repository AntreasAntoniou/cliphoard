import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { spawn, spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { base64url, decode, randomToken, approvalMessage, tokenDigest, canonicalDevice } from '../protocol.mjs';
import { fixture } from './fixtures.mjs';

// Only public values and signatures travel through stdin/stdout. The Swift device key
// and JS issuer key are newly generated and live in their respective processes only.
const harness = `
import Foundation
import CryptoKit
actor MemoryDevice: DeviceLicenceKeyProvider {
    let key = P256.Signing.PrivateKey()
    var lastMessage = Data()
    var lastSignature = Data()
    func publicKeyX963() async throws -> Data { key.publicKey.x963Representation }
    func signLicenceProof(_ message: Data) async throws -> Data {
        lastMessage = message
        lastSignature = try key.signature(for: message).rawRepresentation
        return lastSignature
    }
}
@main struct Harness {
    static func output(_ object: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
    static func fromBase64URL(_ value: String) -> Data {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)!
    }
    static func main() async throws {
        let device = MemoryDevice()
        try await output(["publicKey": DeviceLicenceVerifier.encode(device.publicKeyX963())])
        while let line = readLine() {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            switch object["operation"] {
            case "sign":
                let signature = try await device.signLicenceProof(fromBase64URL(object["message"]!))
                try output(["signature": DeviceLicenceVerifier.encode(signature)])
            case "verify":
                let result = await DeviceLicenceVerifier.verify(object["receipt"]!, using: device,
                    trustedIssuers: ["synthetic-1": fromBase64URL(object["issuer"]!)])
                switch result {
                case .success(let receipt):
                    let message = await device.lastMessage
                    let signature = await device.lastSignature
                    try output(["verified": true, "receiptID": receipt.receiptID,
                        "proofMessage": DeviceLicenceVerifier.encode(message),
                        "proofSignature": DeviceLicenceVerifier.encode(signature)])
                case .failure: try output(["verified": false])
                }
            case "finish": return
            default: throw DeviceLicenceFailure.malformed
            }
        }
    }
}
`;

test('actual Swift verifier and CryptoKit device complete synthetic WebCrypto email approval end to end', { timeout: 60000 }, async () => {
  const base = new URL('../.test-tmp/', import.meta.url);
  await mkdir(base, { recursive: true, mode: 0o700 });
  const directory = await mkdtemp(fileURLToPath(new URL('interop-', base)));
  let child;
  try {
    const harnessPath = directory + '/Harness.swift'; const binary = directory + '/interop';
    await writeFile(harnessPath, harness, { mode: 0o600 });
    const source = fileURLToPath(new URL('../../../Sources/Cliphoard/Support/DeviceLicence.swift', import.meta.url));
    const compiled = spawnSync('/usr/bin/swiftc', ['-DCLIPHOARD_DEVICE_LICENSING_PROTOTYPE', '-parse-as-library', source, harnessPath, '-o', binary],
      { encoding: 'utf8', timeout: 45000, maxBuffer: 100000 });
    assert.equal(compiled.status, 0, 'interop harness compiles against unmodified actual source: ' + compiled.stderr.slice(0, 3000));
    child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    const closed = once(child, 'close');
    const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    const receive = async () => {
      const line = await lines.next(); assert.equal(line.done, false, 'Swift must return a protocol response');
      return JSON.parse(line.value);
    };
    const send = object => child.stdin.write(JSON.stringify(object) + '\n');
    const { publicKey } = await receive();
    const f = await fixture();
    const { challenge } = await f.start(randomToken(16), { publicKey });
    const approvalRequestID = randomToken(16); const approvalToken = f.mails[0].token;
    send({ operation: 'sign', message: base64url(approvalMessage(challenge, await tokenDigest(approvalToken), approvalRequestID)) });
    const { signature } = await receive();
    const issued = await f.service.approve({ method: 'POST', challengeID: challenge.challengeID, approvalToken,
      approvalRequestID, deviceSignature: signature });
    assert.equal(issued.code, 'issued');
    send({ operation: 'verify', receipt: issued.receipt, issuer: f.signer.publicKey });
    const checked = await receive();
    assert.equal(checked.verified, true);
    const publicDevice = await canonicalDevice(publicKey);
    assert.equal(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicDevice.key,
      decode(checked.proofSignature, 64), decode(checked.proofMessage)), true);
    send({ operation: 'verify', receipt: issued.receipt.replace('CLIPD1.', 'CLIPD2.'), issuer: f.signer.publicKey });
    assert.equal((await receive()).verified, false);
    send({ operation: 'finish' }); child.stdin.end();
    assert.equal((await closed)[0], 0);
  } finally {
    if (child && child.exitCode === null) child.kill();
    await rm(directory, { recursive: true, force: true });
  }
});
