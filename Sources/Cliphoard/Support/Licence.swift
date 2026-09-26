import CryptoKit
import Foundation

/// What a user is entitled to. Passed as a VALUE into the gated call sites rather than read
/// from a global — the repo's own idiom (`HistoryReaper` takes a `CompleteHistory` token) so
/// the unsafe state is unrepresentable rather than merely discouraged.
enum Entitlement: Equatable {
    case free(reason: String?)
    case pro(orderID: String, issued: Date)

    var isPro: Bool { if case .pro = self { return true }; return false }
}

/// Offline Pro licence: an Ed25519 signature over a small JSON payload, verified against a
/// public key compiled in here. No network, no account, no Keychain, no file I/O — `verify`
/// is pure and total. The site promises "zero network calls" in three places, and a licence
/// check that phoned home would make every one of them a lie.
///
/// THE KEY IS A REQUEST BACKED BY A SIGNATURE, NOT A LOCK. The source is MIT; anyone can
/// remove this check. People who pay do so for convenience and to fund the work, which is
/// how every indie open-core app has ever worked. Say that out loud rather than pretend.
///
/// Format: `CLIP1-<b64url(payload)>.<b64url(sig)>` — the separator is `.`, which is outside the
/// base64url alphabet (`-` is IN it, and a first draft that split on `-` rejected its own valid keys)., payload = compact JSON
/// `{"o":"<order-id>","i":<epoch>,"p":"pro","v":1}`. The `v` field is the only upgrade lever
/// available offline: a 2.0 may require `v ≥ 2`. Keys never expire and cannot be revoked —
/// that is what makes them honest as a one-time purchase.
///
/// Storage is UserDefaults, deliberately NOT the Keychain: STATUS.md records a keychain
/// incident that froze the maintainer's own install read-only. A licence must keep working
/// when the store is frozen; a paying customer locked out by a Keychain fault is a refund.
/// The key is public data signed by a private key — it has no confidentiality requirement,
/// and a forged `defaults write` fails the signature.
enum Licence {
    /// The 32 raw bytes of the Ed25519 public key. The private half lives outside the repo
    /// (`~/.cliphoard-licensing/`) and is read only by `Scripts/issue-licence.swift`.
    static let publicKey: [UInt8] = [0xdf, 0x85, 0x05, 0x00, 0x81, 0x23, 0xf0, 0x79, 0x0a, 0xa4, 0xc8, 0xf0, 0x71, 0xc9, 0xfc, 0xf3, 0x8e, 0x31, 0x47, 0x5d, 0xa8, 0x51, 0xac, 0xe2, 0x8e, 0xc6, 0x3c, 0xa5, 0x9a, 0x8c, 0xbf, 0x26]

    static let prefix = "CLIP1-"
    static let defaultsKey = "licenceKey"

    /// Pure verification. Never throws, never blocks, touches nothing outside its arguments.
    static func verify(_ key: String, now: Date = Date()) -> Entitlement {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return .free(reason: trimmed.isEmpty ? nil : "not a Cliphoard key") }
        let parts = trimmed.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = b64urlDecode(String(parts[0])),
              let sig = b64urlDecode(String(parts[1])), sig.count == 64
        else { return .free(reason: "malformed key") }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKey)),
              pub.isValidSignature(sig, for: payload)
        else { return .free(reason: "signature does not verify") }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let order = obj["o"] as? String, !order.isEmpty,
              let issued = obj["i"] as? Double,
              (obj["p"] as? String) == "pro",
              let v = obj["v"] as? Int, v >= 1
        else { return .free(reason: "signature valid but payload unrecognised") }
        return .pro(orderID: order, issued: Date(timeIntervalSince1970: issued))
    }

    /// The stored key's entitlement. Read live, never cached, so a paste in Settings takes
    /// effect at once and a removed key takes effect at once.
    static var current: Entitlement {
        verify(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    static func store(_ key: String) { UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKey) }
    static func remove() { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    /// Where to buy. One place, so the upsell surfaces cannot drift.
    static let buyURL = URL(string: "https://cliphoard.dev/#pro")!

    /// The price, written ONCE. Every upsell surface names it, and each copy of the number
    /// is a chance for the app to quote a price the checkout does not charge — which
    /// for a paid product is not a typo, it is a false statement about money.
    static let priceLabel = "$10"

    /// What the gated surfaces say when they refuse. One sentence, one place, so the two
    /// search-mode pickers and the image-text toggle cannot end up describing different
    /// products.
    static let pitch = "Cliphoard Pro — \(priceLabel) once, on this Mac and every Mac you own."

    private static func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
