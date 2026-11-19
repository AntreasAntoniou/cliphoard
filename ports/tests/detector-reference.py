"""Generate synthetic safety goldens with the shipping Mac detector source."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'Sources/Cliphoard/Search/Detectors.swift'
samples = [
    '', 'Synthetic ordinary clipboard note', 'restaurant serves delicious meals',
    '2026-11-16 12:34:56', 'getElementByIdAndCacheIt',
    '550e8400-e29b-41d4-a716-446655440000', 'a'*40,
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    '/Users/synthetic/2026/report_v2.pdf', 'a-long-source-identifier-with-2026-characters.swift',
    'VGhpcyBpcyBhIHN5bnRoZXRpYyBwbGFpbiB0ZXh0IGV4YW1wbGU=',
    'mF9Kp2Rz8Tq4Wv6Xb1Hd3Ns7', 'aB7!cD9@eF2#hJ4$',
    '-----BEGIN PRIVATE KEY----- synthetic fixture only',
    'AKIA'+'A1'*8, 'ghp_'+'aB1cD2'*4, 'xoxb-'+'1a2b3c4d5e6f',
    'sk_live_'+'aB1cD2'*4, 'AIza'+'aB1cD2'*6, 'sk-'+'aB1cD2'*4,
    'eyJhbGciOiJub25lIn0.eyJzdWIiOiJzeW50aGV0aWMifQ.',
    'ask-me-later ordinary prose', 'hello synthetic@example.com.', 'user@localhost', '@synthetic',
    '+44 7700 900123', '07700900123', '2026-08-06 12:34:56',
    '4111 1111 1111 1111', '4111 1111 1111 1112', '378282246310005',
    '021000021', '021000022', 'GB82 WEST 1234 5698 7654 32', 'GB81WEST12345698765432',
    '1BoatSLRHtKNngkdXEeobR76b53LETtpyT', '1BoatSLRHtKNngkdXEeobR76b53LETtpyU',
    '0x52908400098527886E0F7030069857D2E4169EE7',
    '0x5Aeda56215b167893e80B4fE645BA6d5Bab767DE',
    '0x5Aeda56215b167893e80B4fE645BA6d5Bab767De',
    '123-45-6789', '000-00-0000', '666-45-6789', '046 454 286', '046 454 287',
    'AB123456C', 'ZZ123456C', 'DF123456C',
    '221B Baker Street London NW1 6XE', '10 Synthetic Road London SW1A 1AA',
    'The High Street is busy', 'Synthetic Street report 2026',
    'Verification code 482913', 'synthetic invoice 482913', 'your OTP is 1234',
    'https://example.com/login?token=mF9Kp2Rz8Tq4Wv6Xb1Hd3Ns7',
    'https://example.com/docs?value=ordinary', 'Café 中文 synthetic note',
]
cases = [{'text': text, 'source': None} for text in samples]
cases += [{'text': 'Synthetic note', 'source': value} for value in ['1Password','com.apple.Passwords','com.bitwarden.desktop','Synthetic Editor']]
main = r'''
import Foundation
enum ClipKind { case text, link, color, image, file }
struct Sample: Codable { let text: String; let source: String? }
struct Result: Codable { let text: String; let source: String?; let flags: Int; let shape: String? }
@main struct Reference {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let samples = try JSONDecoder().decode([Sample].self, from: input)
        let results = samples.map { sample in
            let verdict = Detectors.scan(text: sample.text, kind: .text, sourceApp: sample.source)
            return Result(text: sample.text, source: sample.source, flags: verdict.flags.rawValue, shape: verdict.shape)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
'''
with tempfile.TemporaryDirectory(prefix='cliphoard-detector-reference-') as directory:
    temporary = Path(directory)
    (temporary/'Reference.swift').write_text(main)
    subprocess.run(['/usr/bin/swiftc','-O',str(source),str(temporary/'Reference.swift'),'-o',str(temporary/'reference')],check=True)
    output = subprocess.check_output([str(temporary/'reference')],input=json.dumps(cases).encode())
fixture = {'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'samples':json.loads(output)}
(root/'ports/windows/NativeTests/Fixtures/Detectors.json').write_text(json.dumps(fixture,ensure_ascii=False,separators=(',',':'))+'\n')
print(f'Generated {len(cases)} shipping Mac detector goldens with synthetic inputs')
