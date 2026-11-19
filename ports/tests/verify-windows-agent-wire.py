"""Verify Windows synthetic frames with the unchanged shipping Mac protocol."""
from pathlib import Path
import base64
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
command = "[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\\CliphoardDev\\evidence\\windows-agent-wire.json'))"
result = subprocess.run(['/usr/local/bin/prlctl', 'exec', 'ad50825b-955a-4cd4-a04b-b7fadc860197', '--current-user', 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '-'], input='& {\n' + command + '\n}\n\n', text=True, capture_output=True, check=True)
if len(result.stdout) > 100000:
    raise RuntimeError('Synthetic wire evidence exceeds its bound')
wire = base64.b64decode(result.stdout.strip(), validate=True)
source = (root / 'Sources/Cliphoard/Support/AgentWriteProtocol.swift').read_text()
harness = r'''
@main struct Verify {
    static func main() throws {
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let outbound = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [[String: Any]]
        let now = golden["now"] as! Double
        let session = try AgentWriteProtocol.decodeSession(Data(base64Encoded: golden["session"] as! String)!, now: now)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: golden["privateKey"] as! String)!)
        let samples = golden["samples"] as! [[String: Any]]
        guard outbound.count == samples.count else { fatalError("Synthetic frame count changed") }
        var checks = 0
        for entry in outbound {
            let id = UUID(uuidString: entry["requestID"] as! String)!
            let opened = try AgentWriteProtocol.open(Data(base64Encoded: entry["envelope"] as! String)!, session: session, privateKey: privateKey, now: now)
            guard opened.request.text == entry["text"] as! String, opened.request.requestID == id else { fatalError("Windows request mismatch") }
            checks += 1
            let key = opened.responseKey.withUnsafeBytes { Data($0) }
            guard key == Data(base64Encoded: entry["responseKey"] as! String)! else { fatalError("Windows response key mismatch") }
            checks += 1
            let sample = samples.first { $0["requestID"] as! String == id.uuidString }!
            let prepared = AgentWriteProtocol.Prepared(data: Data(base64Encoded: sample["envelope"] as! String)!, responseKey: SymmetricKey(data: Data(base64Encoded: sample["responseKey"] as! String)!), requestDigest: sample["digest"] as! String, sessionID: session.sessionID, requestID: id)
            let receipt = try AgentWriteProtocol.openReceipt(Data(base64Encoded: entry["receipt"] as! String)!, prepared: prepared, expectedSessionID: session.sessionID, expectedRequestID: id)
            guard receipt.status == .saved, receipt.clipID == id else { fatalError("Windows receipt mismatch") }
            checks += 1
        }
        print("{\"mac_agent_interop_checks\":\(checks),\"status\":\"passed\",\"synthetic_keys_and_notes_only\":true}")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='cliphoard-agent-interop-') as directory:
    directory = Path(directory)
    swift = directory / 'Verify.swift'
    swift.write_text(source + '\n' + harness)
    evidence = directory / 'windows.json'
    evidence.write_bytes(wire)
    binary = directory / 'verify'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root / 'ports/windows/NativeTests/Fixtures/AgentProtocol.json'), str(evidence)], check=True)
