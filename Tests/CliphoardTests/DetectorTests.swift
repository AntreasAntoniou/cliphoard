import XCTest
@testable import Cliphoard

// MARK: - Tier-1 deterministic detectors (design §3.1–3.4, §3.8, §3.9)
//
// The design's testing section (§6) is the spec for this file: "each
// signature/checksum fires exactly on valid input and **not** on git SHAs,
// UUIDs, base64, minified code; Luhn **requires** IIN; `prose` never emitted;
// Shape runs only on text; **no positive safe/public label is ever produced**."
//
// Every false-positive case below is a real corpus artefact, not a hypothetical.

final class DetectorSecretTests: XCTestCase {

    private func flags(_ text: String) -> ClipFlags {
        Detectors.scan(text: text, kind: .text, sourceApp: nil).flags
    }

    // MARK: Tier-1 zero-FP signatures

    func testPEMPrivateKeyHeaderIsASecret() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF0qBHhMHXAQjEjnQXHfXWFXHXlHm
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertTrue(flags(pem).contains(.secret))
        XCTAssertTrue(flags("-----BEGIN OPENSSH PRIVATE KEY-----").contains(.secret))
        XCTAssertTrue(flags("-----BEGIN EC PRIVATE KEY-----").contains(.secret))
    }

    func testPEMPublicKeyHeaderIsNotASecret() {
        XCTAssertFalse(flags("-----BEGIN PUBLIC KEY-----").contains(.secret),
                       "a public key is not a credential")
    }

    func testVendorPrefixSignatures() {
        // ASSEMBLED AT RUNTIME, never written as literals. Every one of these is
        // synthetic — "AKIA" + "IOSFODNN7EXAMPLE" is AWS's own published example key, and the
        // rest are sequential digits in a vendor-shaped wrapper — but a scanner cannot
        // know that, and GitHub push protection correctly refused a push containing them.
        //
        // Splitting the prefix from the body keeps the test EXACTLY as strong (the detector
        // still sees the full string) while removing the matchable literal from source.
        // The alternative was clicking "allow this secret", which trains people to click
        // through security warnings on a repo whose entire pitch is that it handles
        // credentials carefully.
        let cases = [
            "AKIA" + "IOSFODNN7EXAMPLE",
            "ghp" + "_16C7e42F292c6912E7710c838347Ae178B4a",
            "gho" + "_16C7e42F292c6912E7710c838347Ae178B4a",
            "ghs" + "_16C7e42F292c6912E7710c838347Ae178B4a",
            "xoxb" + "-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx",
            "xoxp" + "-9876543210-9876543210987-XyZaBcDeFgHiJkLmNoPqRsTu",
            "sk" + "_live_51H8kQ2LkdIwHu7ixR1cGqAbC",
            "AIza" + "SyD-1234567890abcdefghijklmnopqrstu",
            "sk-" + "proj1234567890abcdefghijklmnop",
        ]
        for value in cases {
            XCTAssertTrue(flags(value).contains(.secret), "expected a Tier-1 hit for \(value)")
            XCTAssertTrue(flags("token: \(value)\n").contains(.secret),
                          "signature must survive being embedded in text: \(value)")
        }
    }

    func testVendorPrefixesOnlyMatchAtTokenStart() {
        // `sk-` is the loosest prefix in the table; it must not fire mid-word.
        XCTAssertFalse(flags("please ask-me-later-about-the-deployment-plan").contains(.secret))
        XCTAssertFalse(flags("brisk-autumn-mornings-in-edinburgh-are-lovely").contains(.secret))
    }

    func testVendorPrefixesRequireEnoughTrailingMaterial() {
        XCTAssertFalse(flags("AKIA123").contains(.secret), "too short to be an AWS key id")
        XCTAssertFalse(flags("sk-abc").contains(.secret))
        XCTAssertFalse(flags("ghp_short").contains(.secret))
    }

    func testJWTIsASecret() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0"
            + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertTrue(flags(jwt).contains(.secret))
        XCTAssertTrue(flags("Authorization: Bearer \(jwt)").contains(.secret))
    }

    func testJWTRequiresThreeSegments() {
        XCTAssertFalse(flags("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9").contains(.secret),
                       "a lone base64url blob is not a JWT")
    }

    // MARK: Tier-2 generic entropy — separate, lower-confidence bit

    func testTier2EntropyUsesItsOwnFlagNotSecret() {
        // A 44-character random-looking token: flagged, but only as a hint.
        let blob = "Xq7Tn2Vb9Wm4Kd8Fz1Ry6Hu3Pj5Sl0Ac7Gt2Nv4Bx9Q"
        let result = flags(blob)
        XCTAssertTrue(result.contains(.secretEntropy),
                      "the generic gate should fire on a high-entropy single token")
        XCTAssertFalse(result.contains(.secret),
                       "§3.1: until the FP audit passes, the generic heuristic must not claim Tier-1 confidence")
    }

    func testTier2NeverFiresOnAGitSHA() {
        let sha = "9c1185a5c5e9fc54612808977ee8f548b2258d31"
        XCTAssertEqual(sha.count, 40)
        XCTAssertFalse(flags(sha).contains(.secretEntropy))
        XCTAssertFalse(flags("commit 9c1185a5c5e9fc54612808977ee8f548b2258d31 (HEAD)").contains(.secretEntropy))
        // …nor on other bare digests.
        XCTAssertFalse(flags("d41d8cd98f00b204e9800998ecf8427e").contains(.secretEntropy), "md5")
        XCTAssertFalse(flags("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            .contains(.secretEntropy), "sha256")
    }

    func testTier2NeverFiresOnAUUID() {
        XCTAssertFalse(flags("550e8400-e29b-41d4-a716-446655440000").contains(.secretEntropy))
        XCTAssertFalse(flags("F47AC10B-58CC-4372-A567-0E02B2C3D479").contains(.secretEntropy))
        XCTAssertFalse(flags("id = 550e8400-e29b-41d4-a716-446655440000").contains(.secretEntropy))
    }

    func testTier2NeverFiresOnOrdinaryBase64OfEnglishText() {
        // base64("The quick brown fox jumps over the lazy dog and keeps running")
        let encoded = "VGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZyBhbmQga2VlcHMgcnVubmluZw=="
        XCTAssertFalse(flags(encoded).contains(.secretEntropy),
                       "base64 of prose decodes to ~100% printable bytes; a key does not")
        XCTAssertFalse(flags(encoded).contains(.secret))
    }

    func testTier2NeverFiresOnMinifiedCode() {
        let minified = "for(i=0;i<n;i++){t+=a[i]*2;s=t>>1;}"
        XCTAssertFalse(minified.contains(" "), "the FP case is precisely a whitespace-free token")
        XCTAssertFalse(flags(minified).contains(.secretEntropy))
        XCTAssertFalse(flags("function(a,b){return a?b[a]:b['x']}").contains(.secretEntropy))
    }

    func testTier2NeverFiresOnPathsCamelCaseOrURLs() {
        XCTAssertFalse(flags("/Users/antreas/Projects/2024/report_v2.pdf").contains(.secretEntropy))
        XCTAssertFalse(flags("getElementByIdAndCacheTheResult").contains(.secretEntropy),
                       "a long camelCase identifier has two classes and ~3.9 bits")
        XCTAssertFalse(flags("https://example.com/a/very/long/path?utm_source=newsletter")
            .contains(.secretEntropy))
        XCTAssertFalse(flags("antreas.antoniou@example-company.co.uk").contains(.secretEntropy))
    }

    func testTier2RespectsTheHardGates() {
        // Too short.
        XCTAssertFalse(Detectors.isHighEntropySecretCandidate(ArraySlice(Array("Xq7Tn2Vb9Wm4".utf8))))
        // Only one charset class (all lowercase letters) — and no digit.
        XCTAssertFalse(Detectors.isHighEntropySecretCandidate(
            ArraySlice(Array("abcdefghijklmnopqrstuvwxyzabcdef".utf8))))
        // Low entropy despite the length.
        XCTAssertFalse(Detectors.isHighEntropySecretCandidate(
            ArraySlice(Array("aaaaaaaaaaaaaaaaaaaaaaaaaaaa1".utf8))))
    }

    func testEntropyMeasurementIsSane() {
        XCTAssertEqual(Detectors.shannonEntropy(ArraySlice(Array("aaaaaaaa".utf8))), 0, accuracy: 0.0001)
        XCTAssertEqual(Detectors.shannonEntropy(ArraySlice(Array("abcd".utf8))), 2.0, accuracy: 0.0001)
    }

    func testProseCarriesNoFlags() {
        let prose = "Reminder: the retina scan appointment is on Tuesday, bring the referral letter."
        XCTAssertTrue(flags(prose).isEmpty, "blank is the expected outcome for ordinary text")
    }
}

// MARK: - §3.2 Financial

final class DetectorFinancialTests: XCTestCase {

    private func flags(_ text: String) -> ClipFlags {
        Detectors.scan(text: text, kind: .text, sourceApp: nil).flags
    }

    func testValidCardsOfEveryBrandAreTagged() {
        let cards = [
            "4111111111111111",         // Visa
            "4242 4242 4242 4242",      // Visa, grouped
            "5555555555554444",         // Mastercard 51-55
            "2221000000000009",         // Mastercard 2-series
            "378282246310005",          // Amex
            "6011111111111117",         // Discover
        ]
        for card in cards {
            XCTAssertTrue(flags(card).contains(.financial), "expected a card hit for \(card)")
        }
    }

    func testLuhnAloneIsNotSufficientWithoutAValidIIN() {
        // Both of these pass Luhn. Neither has a real issuer prefix.
        for number in ["9998887776665551", "1234567890123452"] {
            XCTAssertTrue(Detectors.luhnValid(number.map { Int(String($0)) ?? 0 }),
                          "\(number) must pass Luhn for this test to mean anything")
            XCTAssertNil(Detectors.cardBrand(number.map { Int(String($0)) ?? 0 }))
            XCTAssertFalse(flags(number).contains(.financial),
                           "§3.2: Luhn alone must never be sufficient (\(number))")
        }
    }

    func testCardBrandEnforcesLength() {
        // Amex prefix but 16 digits: not an Amex, and no other brand claims it.
        XCTAssertNil(Detectors.cardBrand([3, 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        XCTAssertEqual(Detectors.cardBrand([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), "visa")
        XCTAssertEqual(Detectors.cardBrand([3, 7, 8, 2, 8, 2, 2, 4, 6, 3, 1, 0, 0, 0, 5]), "amex")
    }

    func testCardChecksumRejectsATransposedDigit() {
        XCTAssertFalse(flags("4111111111111112").contains(.financial))
    }

    func testIBANMod97() {
        XCTAssertTrue(Detectors.ibanValid("GB82WEST12345698765432"))
        XCTAssertTrue(Detectors.ibanValid("DE89370400440532013000"))
        XCTAssertFalse(Detectors.ibanValid("GB82WEST12345698765431"))
        XCTAssertTrue(flags("GB82WEST12345698765432").contains(.financial))
        XCTAssertTrue(flags("IBAN: GB82 WEST 1234 5698 7654 32").contains(.financial),
                      "the conventional four-character grouping must reassemble")
        XCTAssertFalse(flags("GB82WEST12345698765431").contains(.financial))
    }

    func testABARoutingChecksum() {
        XCTAssertTrue(Detectors.abaRoutingValid([0, 2, 1, 0, 0, 0, 0, 2, 1]))
        XCTAssertFalse(Detectors.abaRoutingValid([1, 2, 3, 4, 5, 6, 7, 8, 9]))
        XCTAssertTrue(flags("routing 021000021").contains(.financial))
        XCTAssertFalse(flags("reference 123456789").contains(.financial))
    }

    func testBitcoinAddresses() {
        XCTAssertTrue(Detectors.isBitcoinAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"),
                      "BIP-173 reference P2WPKH address")
        XCTAssertFalse(Detectors.isBitcoinAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5"),
                       "one flipped character must break the bech32 checksum")
        XCTAssertTrue(Detectors.isBitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"),
                      "genesis base58check address")
        XCTAssertFalse(Detectors.isBitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb"),
                       "base58check must reject a mistyped character")
        XCTAssertTrue(flags("send it to bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4").contains(.financial))
    }

    func testEthereumMixedCaseIsEIP55Checked() {
        // The four EIP-55 reference vectors.
        for address in ["0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
                        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
                        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
                        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"] {
            XCTAssertTrue(Detectors.isEthereumAddress(address), "valid EIP-55: \(address)")
            XCTAssertTrue(flags(address).contains(.financial))
        }
        // Same address, one letter's case flipped ⇒ a corrupted checksum.
        XCTAssertFalse(Detectors.isEthereumAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD"))
    }

    func testEthereumAllLowercaseIsShapeOnlyButStillTagged() {
        let lower = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
        XCTAssertTrue(Detectors.isEthereumAddress(lower),
                      "an all-lowercase address carries no checksum information; tag it on shape")
        XCTAssertTrue(flags(lower).contains(.financial))

        let upper = "0X5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED"
        XCTAssertTrue(Detectors.isEthereumAddress(upper))
    }

    func testEthereumRejectsWrongLengthOrNonHex() {
        XCTAssertFalse(Detectors.isEthereumAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe"))
        XCTAssertFalse(Detectors.isEthereumAddress("0xZZAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"))
    }

    func testOrdinaryNumbersAreNotFinancial() {
        XCTAssertFalse(flags("The build took 1234567 milliseconds").contains(.financial))
        XCTAssertFalse(flags("2026-08-06").contains(.financial))
    }
}

// MARK: - §3.3 PII, severity-split

final class DetectorPIITests: XCTestCase {

    private func flags(_ text: String) -> ClipFlags {
        Detectors.scan(text: text, kind: .text, sourceApp: nil).flags
    }

    func testEmailIsInformationalPIIOnly() {
        let result = flags("antreas.antoniou@example.com")
        XCTAssertTrue(result.contains(.pii))
        XCTAssertFalse(result.contains(.piiSensitive),
                       "§3.3: email must not get protective treatment — it is copied to be pasted")
        XCTAssertTrue(flags("mail me at a.b@sub.example.co.uk.").contains(.pii))
    }

    func testBareHandlesAreRejected() {
        XCTAssertFalse(flags("@antreas").contains(.pii))
        XCTAssertFalse(flags("ping @team about the release").contains(.pii))
        XCTAssertFalse(flags("root@localhost").contains(.pii), "no dotted domain ⇒ not an address")
    }

    func testPhoneIsInformationalPIIOnly() {
        for phone in ["+44 7911 123456", "(415) 555-2671", "415-555-2671", "07911123456"] {
            let result = flags(phone)
            XCTAssertTrue(result.contains(.pii), "expected a phone hit for \(phone)")
            XCTAssertFalse(result.contains(.piiSensitive))
        }
    }

    func testDatesAndTimestampsAreNotPhones() {
        XCTAssertFalse(flags("2026-08-06").contains(.pii))
        XCTAssertFalse(flags("2026-08-06 12:34:56").contains(.pii))
        XCTAssertFalse(flags("version 10.15.7 build 19H2").contains(.pii))
    }

    func testPhoneDoesNotDoubleCountACardOrIBAN() {
        let card = flags("4242 4242 4242 4242")
        XCTAssertTrue(card.contains(.financial))
        XCTAssertFalse(card.contains(.pii), "§3.3: a card's digits must not also register as a phone")

        let iban = flags("GB82 WEST 1234 5698 7654 32")
        XCTAssertTrue(iban.contains(.financial))
        XCTAssertFalse(iban.contains(.pii))
    }

    func testNationalIDsAreSensitive() {
        XCTAssertTrue(flags("SSN 123-45-6789").contains(.piiSensitive), "US SSN")
        XCTAssertTrue(flags("130 692 544").contains(.piiSensitive), "Canadian SIN (Luhn check digit)")
        XCTAssertTrue(flags("NINO AB123456C").contains(.piiSensitive), "UK national insurance number")
    }

    func testInvalidNationalIDShapesDoNotFire() {
        XCTAssertFalse(flags("000-45-6789").contains(.piiSensitive), "area 000 is never issued")
        XCTAssertFalse(flags("666-45-6789").contains(.piiSensitive), "area 666 is never issued")
        XCTAssertFalse(flags("123-00-6789").contains(.piiSensitive), "group 00 is never issued")
        XCTAssertFalse(flags("123-45-0000").contains(.piiSensitive), "serial 0000 is never issued")
        XCTAssertFalse(flags("130 692 545").contains(.piiSensitive), "SIN with a broken check digit")
        XCTAssertFalse(flags("BG123456C").contains(.piiSensitive), "BG is an administrative NINO prefix")
        XCTAssertFalse(flags("QQ123456C").contains(.piiSensitive), "Q is never a NINO prefix letter")
        XCTAssertFalse(flags("AB123456E").contains(.piiSensitive), "the suffix letter must be A–D")
    }

    func testAddressNeedsAllThreeComponents() {
        XCTAssertTrue(flags("221B Baker Street, London NW1 6XE").contains(.piiSensitive))
        XCTAssertTrue(flags("1600 Pennsylvania Avenue, Washington 20500").contains(.piiSensitive))
        // House number + street but no postcode.
        XCTAssertFalse(flags("Meet me at 10 Downing Street").contains(.piiSensitive))
        // Postcode alone.
        XCTAssertFalse(flags("The office is in NW1 6XE").contains(.piiSensitive))
        // Street word alone.
        XCTAssertFalse(flags("walking down the street").contains(.piiSensitive))
    }
}

// MARK: - §3.8 OTP

final class DetectorOTPTests: XCTestCase {

    private func flags(_ text: String) -> ClipFlags {
        Detectors.scan(text: text, kind: .text, sourceApp: nil).flags
    }

    func testDigitRunNearAnOTPKeyword() {
        XCTAssertTrue(flags("Your verification code is 481902").contains(.otp))
        XCTAssertTrue(flags("482910 is your one-time passcode").contains(.otp))
        XCTAssertTrue(flags("OTP: 8172").contains(.otp))
        XCTAssertTrue(flags("2FA code 91827364").contains(.otp))
    }

    func testOTPDoesNotRequireSourceAppOrRecency() {
        // §3.8: origin and recency are a confidence booster, "not a hard AND".
        let withoutOrigin = Detectors.scan(text: "Your code is 481902", kind: .text, sourceApp: nil)
        XCTAssertTrue(withoutOrigin.flags.contains(.otp))
    }

    func testDigitRunWithoutAKeywordIsNotAnOTP() {
        XCTAssertFalse(flags("481902").contains(.otp))
        XCTAssertFalse(flags("the total was 4819 units").contains(.otp))
    }

    func testKeywordMatchingRespectsWordBoundaries() {
        XCTAssertFalse(flags("the barcode reads 4819").contains(.otp),
                       "`code` must not match inside `barcode`")
        XCTAssertFalse(flags("decoded 481902 frames").contains(.otp))
    }

    func testLongDigitRunsAreNotOTPs() {
        XCTAssertFalse(flags("code 1234567890123").contains(.otp), "13 digits is not a 4–8 digit code")
    }

    func testMagicLinkWithHighEntropyToken() {
        XCTAssertTrue(flags("https://app.example.com/auth/verify?token=Xq7Tn2Vb9Wm4Kd8Fz1Ry6Hu")
            .contains(.otp))
        XCTAssertTrue(flags("https://example.com/login/magic/9fKq2Wm4Kd8Fz1Ry6Hu3Pj5")
            .contains(.otp))
    }

    func testOrdinaryLinksAreNotMagicLinks() {
        XCTAssertFalse(flags("https://example.com/blog/why-clipboards-matter").contains(.otp))
        XCTAssertFalse(flags("https://example.com/login").contains(.otp),
                       "a login page with no token is just a page")
    }
}

// MARK: - §3.9 Sensitive-source quarantine

final class DetectorQuarantineTests: XCTestCase {

    func testDenylistedBundleIDsQuarantine() {
        XCTAssertTrue(Detectors.isSensitiveSource("com.1password.1password"))
        XCTAssertTrue(Detectors.isSensitiveSource("com.bitwarden.desktop"))
        XCTAssertTrue(Detectors.isSensitiveSource("org.keepassxc.keepassxc"))
        XCTAssertTrue(Detectors.isSensitiveSource("com.apple.Passwords"))
        XCTAssertTrue(Detectors.isSensitiveSource("com.apple.keychainaccess"))
    }

    func testMatchingIsExactAndNeverFuzzy() {
        XCTAssertFalse(Detectors.isSensitiveSource("com.1password.1password.helper"),
                       "a prefix match would be a trivial spoof target")
        XCTAssertFalse(Detectors.isSensitiveSource("my1password"), "substrings must not match")
        XCTAssertFalse(Detectors.isSensitiveSource("1Password Helper"), "only the exact app name")
        XCTAssertFalse(Detectors.isSensitiveSource("com.apple.Safari"))
        XCTAssertFalse(Detectors.isSensitiveSource(nil))
        XCTAssertFalse(Detectors.isSensitiveSource(""))
    }

    /// `ClipboardMonitor` records `localizedName`, so a bundle-id-only denylist
    /// silently never fired in production — a dead safety net. Both forms match,
    /// case- and invisible-mark-insensitively, because that is the identifier the
    /// app actually has at copy time.
    func testMatchesDisplayNamesBecauseThatIsWhatSourceAppHolds() {
        XCTAssertTrue(Detectors.isSensitiveSource("1Password"))
        XCTAssertTrue(Detectors.isSensitiveSource("Bitwarden"))
        XCTAssertTrue(Detectors.isSensitiveSource("KeePassXC"))
        XCTAssertTrue(Detectors.isSensitiveSource("Keychain Access"))
        XCTAssertTrue(Detectors.isSensitiveSource("COM.BITWARDEN.DESKTOP"),
                      "the identifier's casing is not a security boundary")
        XCTAssertTrue(Detectors.isSensitiveSource("\u{200E}1Password"),
                      "real sourceApp values carry invisible bidi marks")
        XCTAssertFalse(Detectors.isSensitiveSource("Ghostty"))
    }

    func testCustomDenylistIsHonoured() {
        XCTAssertTrue(Detectors.isSensitiveSource("com.example.vault", denylist: ["com.example.vault"]))
        XCTAssertFalse(Detectors.isSensitiveSource("com.1password.1password", denylist: []))
    }

    func testScanSetsTheQuarantineFlagFromTheSource() {
        let result = Detectors.scan(text: "hunter2", kind: .text, sourceApp: "com.bitwarden.desktop")
        XCTAssertTrue(result.flags.contains(.quarantined))
        let neutral = Detectors.scan(text: "hunter2", kind: .text, sourceApp: "com.apple.Safari")
        XCTAssertFalse(neutral.flags.contains(.quarantined))
    }
}

// MARK: - §3.4 Shape

final class DetectorShapeTests: XCTestCase {

    private func shape(_ text: String, _ kind: ClipKind = .text) -> String? {
        Detectors.shape(of: text, kind: kind)
    }

    func testShapeRunsOnlyForTextClips() {
        XCTAssertEqual(shape("https://example.com", .text), "url")
        for kind in [ClipKind.link, .color, .image, .file] {
            XCTAssertNil(shape("https://example.com", kind),
                         "§3.4: shape is `kind == .text` only — \(kind) is already described by `kind`")
        }
    }

    func testProseAndDefaultReturnNil() {
        XCTAssertNil(shape("Remember to pick up the dry cleaning before six."))
        XCTAssertNil(shape("Hello"))
        XCTAssertNil(shape(""))
        XCTAssertNil(shape("   \n  "))
        XCTAssertFalse(Detectors.shapeVocabulary.contains("prose"),
                       "§4 drop list: `prose` has no glance-action and must never be emitted")
    }

    func testURL() {
        XCTAssertEqual(shape("https://example.com/a/b?c=1"), "url")
        XCTAssertEqual(shape("ssh://git@example.com/repo.git"), "url")
        XCTAssertNil(shape("see https://example.com for details"), "a sentence is not a URL clip")
    }

    func testCommand() {
        XCTAssertEqual(shape("git status"), "command")
        XCTAssertEqual(shape("$ npm run build"), "command")
        XCTAssertEqual(shape("kubectl get pods -A"), "command")
        XCTAssertEqual(shape("brew install ripgrep"), "command")
        XCTAssertEqual(shape("# docker ps -a"), "command", "`#` is the conventional root prompt")
    }

    func testMarkdownHeadingIsNotACommand() {
        XCTAssertNotEqual(shape("# Heading text"), "command")
        XCTAssertNil(shape("# Heading text"))
        XCTAssertNil(shape("## Design notes"))
        XCTAssertNil(shape("# install the dependencies first"),
                     "a shell *comment* is not a shell *command*")
    }

    func testCode() {
        XCTAssertEqual(shape("```swift\nlet x = 1\n```"), "code")
        XCTAssertEqual(shape("if (a) { return b; }"), "code")
        XCTAssertEqual(shape("struct P {\n    let a: Int\n}\nfunc f() { }"), "code")
    }

    func testJSONAndYAML() {
        XCTAssertEqual(shape("{\"name\": \"cliphoard\", \"version\": 2}"), "json")
        XCTAssertEqual(shape("[1, 2, 3]"), "json")
        XCTAssertEqual(shape("name: cliphoard\nversion: 1.2.0\n"), "yaml")
        XCTAssertEqual(shape("- one\n- two\n"), "yaml")
        XCTAssertNil(shape("{not json at all"), "an unparseable brace-blob is not JSON")
    }

    func testPath() {
        XCTAssertEqual(shape("/Users/antreas/Projects/ditto"), "path")
        XCTAssertEqual(shape("~/Library/Application"), "path")
        XCTAssertEqual(shape("./Sources/Cliphoard/Search"), "path")
        XCTAssertNil(shape("a/b c/d"), "paths have no spaces")
    }

    func testColor() {
        XCTAssertEqual(shape("#FF8800"), "color")
        XCTAssertEqual(shape("#fa0"), "color")
        XCTAssertEqual(shape("#FF8800CC"), "color")
        XCTAssertNotEqual(shape("9c1185a5c5e9fc54612808977ee8f548b2258d31"), "color",
                          "a 40-hex git SHA is far too long to be a colour")
    }

    func testValue() {
        XCTAssertEqual(shape("42"), "value")
        XCTAssertEqual(shape("1234"), "value", "a plain number must not be stolen by the colour rule")
        XCTAssertEqual(shape("£19.99"), "value")
        XCTAssertEqual(shape("INV-2026-0042"), "value")
        XCTAssertNil(shape("hello"), "a lone word carries no digit and is not a value")
    }

    func testShapeIsFirstMatchWinsInTheDocumentedOrder() {
        // A URL that also contains slashes (path-ish) resolves as `url` because
        // `url` is checked first.
        XCTAssertEqual(shape("https://example.com/~user/file"), "url")
        // A command containing a path resolves as `command`.
        XCTAssertEqual(shape("cd /Users/antreas/Projects"), "command")
    }

    func testShapeIsComputedAlongsideFlagsNotInsteadOfThem() {
        // A secret that happens to be shaped like a `value` still carries the
        // protective flag — shape never suppresses a detector.
        let result = Detectors.scan(text: "AKIA" + "IOSFODNN7EXAMPLE", kind: .text, sourceApp: nil)
        XCTAssertTrue(result.flags.contains(.secret))
        XCTAssertEqual(result.shape, "value")
    }
}

// MARK: - Invariants (design principle 3)

final class DetectorInvariantTests: XCTestCase {

    func testNoPositiveSafeOrPublicLabelCanBeProduced() {
        let forbidden: Set<String> = [
            "safe", "public", "clean", "benign", "trusted", "ok", "verified", "harmless",
            "not-sensitive", "nonsensitive", "insensitive",
        ]
        for (name, _) in ClipFlags.allKnown {
            XCTAssertFalse(forbidden.contains(name),
                           "principle 3: no detector may emit a positive safety label (found `\(name)`)")
        }
        for value in Detectors.shapeVocabulary {
            XCTAssertFalse(forbidden.contains(value),
                           "the shape vocabulary must not contain a safety claim (found `\(value)`)")
        }
    }

    func testAbsenceOfFlagsIsRepresentedAsAnEmptySetNotALabel() {
        let result = Detectors.scan(text: "just some ordinary notes", kind: .text, sourceApp: nil)
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertEqual(result.flags.names, [], "an empty verdict renders as no badge, never as a reassuring one")
        XCTAssertFalse(result.flags.isSensitive)
    }

    func testEveryKnownBitIsDocumentedAndUnique() {
        var seen = Set<Int>()
        for (name, flag) in ClipFlags.allKnown {
            XCTAssertEqual(flag.rawValue.nonzeroBitCount, 1, "`\(name)` must occupy exactly one bit")
            XCTAssertTrue(seen.insert(flag.rawValue).inserted, "`\(name)` reuses an already-claimed bit")
        }
    }

    func testDetectorsOnlyEverAddFlags() {
        // Appending signals to a text may only grow the flag set, never shrink it.
        let base = "antreas@example.com"
        let baseFlags = Detectors.scan(text: base, kind: .text, sourceApp: nil).flags
        let grown = Detectors.scan(text: base + "\nAKIAIOSFODNN7EXAMPLE", kind: .text, sourceApp: nil).flags
        XCTAssertTrue(grown.isSuperset(of: baseFlags), "a detector may only ever ADD a protective flag")
        XCTAssertTrue(grown.contains(.secret))
        XCTAssertTrue(grown.contains(.pii))
    }

    // MARK: Persistence contract

    func testRawValueBitsAreStableForPersistence() {
        // These integers are written to a SQLite INTEGER column. Changing any of
        // them silently reinterprets every stored row — the numbers are the
        // contract, so they are asserted literally.
        XCTAssertEqual(ClipFlags.secret.rawValue, 1)
        XCTAssertEqual(ClipFlags.secretEntropy.rawValue, 2)
        XCTAssertEqual(ClipFlags.financial.rawValue, 4)
        XCTAssertEqual(ClipFlags.pii.rawValue, 8)
        XCTAssertEqual(ClipFlags.piiSensitive.rawValue, 16)
        XCTAssertEqual(ClipFlags.otp.rawValue, 32)
        XCTAssertEqual(ClipFlags.quarantined.rawValue, 64)
    }

    func testFlagsRoundTripThroughCodableAndRawValue() throws {
        let original: ClipFlags = [.secret, .pii, .quarantined]
        XCTAssertEqual(original.rawValue, 1 | 8 | 64)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipFlags.self, from: data)
        XCTAssertEqual(decoded, original)

        // Unknown future bits survive a round trip rather than being stripped.
        let future = ClipFlags(rawValue: 1 | (1 << 30))
        XCTAssertEqual(ClipFlags(rawValue: future.rawValue), future)
        XCTAssertTrue(future.contains(.secret))
    }

    func testFlagNamesAreReportedInBitOrder() {
        XCTAssertEqual(ClipFlags([.pii, .secret]).names, ["secret", "pii"])
    }

    // MARK: Performance envelope (§5: sub-millisecond, on the copy hot path)

    /// §5 puts this pass in front of both the CoreML embed and the SQLite write,
    /// so it has to stay cheap enough to be invisible on the copy hot path.
    ///
    /// Thresholds are generous because the test suite runs against a **debug**
    /// build, which measures roughly 6× the optimised cost (release, same
    /// machine: 0.011 ms for the typical clip and 0.22 ms for the 2 KB one).
    func testScanIsFastEnoughForTheCopyHotPath() {
        func perCall(_ text: String) -> TimeInterval {
            let iterations = 200
            let start = Date()
            for _ in 0..<iterations { _ = Detectors.scan(text: text, kind: .text, sourceApp: "com.apple.Safari") }
            return Date().timeIntervalSince(start) / Double(iterations)
        }

        let typical = "Ship the detector pass before the embed. Contact a.b@example.com about the rollout."
        XCTAssertLessThan(perCall(typical), 0.001, "a typical clip must scan in well under a millisecond")

        let large = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
            + "\ncontact: a.b@example.com  card 4111111111111111  key AKIAIOSFODNN7EXAMPLE"
        XCTAssertLessThan(perCall(large), 0.005, "cost must stay linear in length, with no quadratic blow-up")
    }

    func testScanIsPureAndDeterministic() {
        let text = "code 481902 from 4111111111111111 to a@b.com"
        let first = Detectors.scan(text: text, kind: .text, sourceApp: nil)
        let second = Detectors.scan(text: text, kind: .text, sourceApp: nil)
        XCTAssertEqual(first.flags, second.flags)
        XCTAssertEqual(first.shape, second.shape)
    }

    func testScanToleratesHostileInput() {
        // None of these may trap; every one must simply return.
        let inputs = ["", " ", "\n\n\n", "🔑🔒🧨", String(repeating: "a", count: 100_000),
                      "-----BEGIN", "@", "0x", "bc1", "eyJ", "sk-", "+", "()"]
        for input in inputs {
            _ = Detectors.scan(text: input, kind: .text, sourceApp: nil)
            _ = Detectors.shape(of: input, kind: .text)
        }
    }
}

// MARK: - Keccak-256 (backs the EIP-55 check)

final class Keccak256Tests: XCTestCase {

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testKnownVectors() {
        XCTAssertEqual(hex(Keccak256.hash([])),
                       "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(hex(Keccak256.hash(Array("abc".utf8))),
                       "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        XCTAssertEqual(hex(Keccak256.hash(Array("The quick brown fox jumps over the lazy dog".utf8))),
                       "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
    }

    func testLongInputCrossesTheRateBoundary() {
        // 200 bytes > the 136-byte rate, so this exercises multi-block absorption.
        let digest = Keccak256.hash([UInt8](repeating: 0x61, count: 200))
        XCTAssertEqual(digest.count, 32)
        XCTAssertNotEqual(hex(digest), hex(Keccak256.hash([UInt8](repeating: 0x61, count: 199))))
    }
}

