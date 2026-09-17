import Foundation

/// The licence seam for moving a history between Macs.
///
/// ONE LINE, consulted at exactly four sites: the Export button, the Import button, and
/// the two command-line flags. The CLI must carry it or the gate is a one-flag bypass —
/// which is the shape of gate this codebase has had to fix before.
///
/// It ships `true`. Gating export is gating the user's EXIT from the product, and for a
/// tool whose whole public argument is "your clipboard never leaves your Mac and you can
/// read the source", charging for the door out inverts the pitch. Three public documents
/// and the changelog promised this as the 1.0.1 fix for a limitation the encryption design
/// itself creates; the first paid feature should not be the way out of your own lock-in.
///
/// If that is ever revisited, note what the one-line framing hides: there is no StoreKit
/// and no licensing code anywhere in this repository, so choosing Pro also means an upsell
/// row, a purchase flow, a restore path and a receipt-validation story. The gate is one
/// line; the feature behind it is not.
enum ProGate {
    static var allowsHistoryArchive: Bool { true }
}
