"""Generate synthetic wire goldens with the unchanged shipping Mac protocol."""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'Sources/Cliphoard/Support/AgentWriteProtocol.swift').read_text()
harness = r'''
@main struct Reference {
    static func main() throws {
        let now = 2_000_000_000.125
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let session = AgentWriteProtocol.Session(sessionID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!, expiresAt: now + 900, publicKey: privateKey.publicKey.rawRepresentation)
        let sessionBytes = try AgentWriteProtocol.encodeSession(session, now: now)
        var samples: [[String: Any]] = []
        for (index, text) in ["synthetic agent note", "synthetic café — α", "synthetic emoji 🦊\nquoted \"note\" / path", "synthetic control\tline\rnext"].enumerated() {
            let id = UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", index + 1))!
            let request = AgentWriteProtocol.Request(sessionID: session.sessionID, requestID: id, createdAt: now, text: text)
            let prepared = try AgentWriteProtocol.prepare(request, session: session, now: now)
            let opened = try AgentWriteProtocol.open(prepared.data, session: session, privateKey: privateKey, now: now)
            let receipt = try AgentWriteProtocol.sealReceipt(status: .saved, opened: opened)
            _ = try AgentWriteProtocol.openReceipt(receipt, prepared: prepared, expectedSessionID: session.sessionID, expectedRequestID: id)
            samples.append(["text": text, "requestID": id.uuidString, "envelope": prepared.data.base64EncodedString(), "responseKey": prepared.responseKey.withUnsafeBytes { Data($0).base64EncodedString() }, "receipt": receipt.base64EncodedString(), "digest": prepared.requestDigest])
        }
        let result: [String: Any] = ["generatedDataOnly": true, "now": now, "privateKey": privateKey.rawRepresentation.base64EncodedString(), "session": sessionBytes.base64EncodedString(), "samples": samples]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='cliphoard-agent-goldens-') as directory:
    directory = Path(directory)
    swift = directory / 'Reference.swift'
    swift.write_text(source + '\n' + harness)
    binary = directory / 'reference'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    data = subprocess.check_output([str(binary)])
    result = json.loads(data)
    destination = root / 'ports/windows/NativeTests/Fixtures/AgentProtocol.json'
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('Generated', len(result['samples']), 'synthetic Mac protocol samples')
