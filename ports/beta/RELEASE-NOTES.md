# Cliphoard Windows 1.2.14 — private beta

19 November 2026

- Supplied teal Cliphoard mascot in the pane, with a transparent background; supplied purple-backed desktop/app icon.
- Sharper PNG and DIB image previews. Cards decode at up to a 1,024-pixel target; Inspect uses original-resolution decoding. Stored images and clipboard conversion retain their existing bounds.
- Twelve original copy cues alongside five Windows system sounds; selection and preview in General settings.
- History validation before durable writes prevents invalid NUL-containing or oversized text from producing a database that cannot reopen.
- Existing local history, pinning, filtering, optional semantic/image/speech models, OCR, archive import/export and native paste safeguards remain included.

## Evidence

The Windows ARM64 core benchmark completed 23 suites and 860 checks with zero failures. The sound fixture passed 126 checks, and branding passed 49. Distribution parsing/licence checks passed 18 additional assertions. These are synthetic assertions, not 878 end-to-end user scenarios.

The current x64 fixture build also completed 23 suites and 860 checks with zero failures under ARM64 emulation. Both packaged release executables refused all four test-only launch flags with exit 78. MSI validation and MSIX structural packaging checks passed for both architectures; unsigned MSIX files are not included in the tester kits.

The ARM64 1.2.14 upgrade succeeded. All 960 installed files matched their manifest, and all four history files present during the upgrade retained their hashes. Fine-detail PNG and DIB previews and PNG inspection were observed in the guest. This does not establish fresh-install/uninstall qualification on another device.

Search quality remains open: 41 misses in the 432-query synthetic retrieval evaluation. See KNOWN-ISSUES.md for qualification limits, unsigned distribution and x64 coverage. This beta does not claim full platform qualification or exhaustive feature parity.
