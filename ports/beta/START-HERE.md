# Cliphoard for Windows — private beta 1.2.14

19 November 2026 · Application version 1.2.14.0

This is a private, unsigned Windows beta. Please read KNOWN-ISSUES.md before installing. It is intended for feedback on everyday clipboard workflows, not production qualification or sensitive-data testing.

## Choose the right installer

Open Windows Settings → System → About and read System type.

| Windows device | Installer |
| --- | --- |
| ARM-based PC, including Windows 11 on Apple Silicon in Parallels | `Cliphoard-1.2.14.0-arm64.msi` |
| Intel or AMD 64-bit PC | `Cliphoard-1.2.14.0-x64.msi` |

This beta targets Windows 11. Windows 10 is not qualified for this beta. No separate .NET installation is required. The x64 version has been tested under ARM64 emulation; native Intel/AMD testing is still needed.

## Install or upgrade

1. Extract this beta kit into a local folder. Install only a package received directly from the beta organiser.
2. In PowerShell, run `Get-FileHash .\Cliphoard-1.2.14.0-arm64.msi -Algorithm SHA256` (substitute `x64` for that kit). Compare the result with SHA256SUMS.txt and the checksum received separately from the organiser. A matching hash establishes file integrity, not publisher identity.
3. Quit any running Cliphoard normally with Ctrl+Q. Resolve any unsaved-history prompt before proceeding.
4. Double-click the MSI and complete the normal installer. It installs for your Windows user without requiring administrator privileges. These binaries are unsigned. If Windows or your organisation blocks installation, stop and report it; do not disable security protections or install a certificate.
5. Open **Cliphoard Windows** from Start or its desktop shortcut. Keep it running as a normal user.

Installation and upgrades retain history. Before upgrading an existing beta, use the app's Backup settings to export an archive if you want a separate recovery copy. Do not send that archive to testers or the organiser.

## Try the app

- Copy a harmless sentence in Notepad. Press **Ctrl+Alt+Shift+B** to open the bottom pane. Select the sentence and press Enter to paste into the application you were using. Ctrl+C copies a selection without automatic paste; Escape dismisses the pane.
- The alternative shortcut **Ctrl+Alt+Shift+V** may be intercepted by macOS when running Windows in a VM. On a Mac keyboard with the guest focused, use **Control+Option+Shift+B**.
- Settings → General contains **Play sound on copy**, **Copy sound** and **Preview sound**. There are 17 choices.
- Settings → Search exposes optional model downloads. Choose and explicitly prepare a model before testing semantic or image search; weights are not included in this installer. Downloads need internet access and may be large. Exact matching works without a downloaded model. Read any readiness or preparation message before evaluating results.
- Clipboard history and derived content are stored locally. Optional model acquisition and release checks contact their respective hosts; this beta is not an entirely network-free app. There is no automatic beta installer update. Obtain newer beta kits from the organiser; the release checker excludes prereleases.

Use TEST-PLAN.md for a short structured check. Send BUG-REPORT.md back through the channel the organiser provides. There is no automatic upload of your report.

## Remove the app

Quit Cliphoard normally, then uninstall **Cliphoard** from Windows Settings → Apps → Installed apps. Uninstall retains history and downloaded models under `%LOCALAPPDATA%\Cliphoard`; it removes the installed payload and owned startup entry. Do not delete that folder if you want to retain your clips. A downgrade is not a supported in-place recovery operation.
