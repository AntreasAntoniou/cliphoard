// PUBLIC, PREDICTABLE, SYNTHETIC TEST FIXTURES ONLY. NEVER USE IN PRODUCTION.
// P-256 private scalars are deliberately 1 and 2; AES bytes are 0..31.
// The fixed-IV ciphertext below is a precomputed recovery fixture, not an encryptor.
const fixture = {
  "bootstrapSigner": {
    "role": "clipb1-bootstrap-signer",
    "keyID": "synthetic-bootstrap",
    "publicKey": "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU",
    "privateJWK": {
      "kty": "EC",
      "crv": "P-256",
      "x": "axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpY",
      "y": "T-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU",
      "d": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE",
      "ext": false,
      "key_ops": [
        "sign"
      ]
    }
  },
  "receiptSigner": {
    "role": "clipd1-receipt-signer",
    "keyID": "synthetic-receipt",
    "publicKey": "BHzyexiNA09-ilI4AwS1GsPAiWnid_IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E",
    "privateJWK": {
      "kty": "EC",
      "crv": "P-256",
      "x": "fPJ7GI0DT36KUjgDBLUaw8CJaeJ38hs1pgtI_EdmmXg",
      "y": "B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E",
      "d": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI",
      "ext": false,
      "key_ops": [
        "sign"
      ]
    }
  },
  "setupSealer": {
    "role": "clipbs1-setup-sealer",
    "keyID": "synthetic-sealer",
    "keyBytes": [
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      23,
      24,
      25,
      26,
      27,
      28,
      29,
      30,
      31
    ]
  }
};
export function syntheticMaterial() {
  const value = structuredClone(fixture);
  value.setupSealer.keyBytes = new Uint8Array(value.setupSealer.keyBytes);
  return value;
}
export const PRESEALED = Object.freeze({
  "context": "synthetic-only\npresealed-recovery",
  "plaintext": "NEVER PRODUCTION: presealed recovery fixture",
  "envelope": "CLIPBS1.synthetic-sealer.CgsMDQ4PEBESExQV.IfhsjTn9hyf5QI1OiuWqBsc-r13aGZvVhzyvtiM4v4xfBCLIg-KrL-wkhJljKQVen_CH9L3GkI6FwCyo"
});
export const BOOTSTRAP_FIELDS = Object.freeze({ profileID:'synthetic-profile', receiptIssuerKeyID:'synthetic-receipt', entitlementID:'AQEBAQEBAQEBAQEBAQEBAQ', activationHandle:'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI', issuedAt:1800000000 });
export const RECEIPT_FIELDS = Object.freeze({ issuerKeyID:'synthetic-receipt', entitlementID:'AQEBAQEBAQEBAQEBAQEBAQ', deviceKeyHash:'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM', receiptID:'BAQEBAQEBAQEBAQEBAQEBA', issuedAt:1800000000 });
