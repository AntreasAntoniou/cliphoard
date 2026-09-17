#!/usr/bin/env swift
// issue-licence.swift — mint a Cliphoard Pro key. Run by the maintainer, never by CI.
//
//   swift Scripts/issue-licence.swift <order-id>
//
// Reads the Ed25519 private key from $CLIPHOARD_SIGNING_KEY or ~/.cliphoard-licensing/signing-key.ed25519
// (base64 raw representation). The private key must NEVER enter this repository: .gitignore
// excludes *.ed25519 and Scripts/ci-preflight-secrets.sh refuses a checkout that contains one.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2, !args[1].isEmpty else {
    FileHandle.standardError.write(Data("usage: issue-licence.swift <order-id>\n".utf8)); exit(2)
}
let env = ProcessInfo.processInfo.environment
let keyPath = env["CLIPHOARD_SIGNING_KEY"]
    ?? (NSHomeDirectory() + "/.cliphoard-licensing/signing-key.ed25519")
guard let raw = (try? String(contentsOfFile: keyPath, encoding: .utf8))
        .flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("no usable signing key at \(keyPath)\n".utf8)); exit(1)
}
let payload = "{\"o\":\"\(args[1])\",\"i\":\(Int(Date().timeIntervalSince1970)),\"p\":\"pro\",\"v\":1}"
let sig = try! key.signature(for: Data(payload.utf8))
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
print("CLIP1-\(b64url(Data(payload.utf8))).\(b64url(sig))")
