# Homebrew Cask for Cliphoard.
#
# Publish this from a tap repo (e.g. github.com/AntreasAntoniou/homebrew-tap)
# so users can:  brew install --cask antreasantoniou/tap/cliphoard
#
# The `sha256` below is an all-zero PLACEHOLDER. It is NOT a real checksum and
# this cask MUST NOT be published with it. On each release, replace it with the
# sha256 of the RELEASED DMG (Cliphoard-<version>.dmg): the release CI computes and
# prints it — see Scripts/release.sh (which packages the DMG) and
# .github/workflows/release.yml ("Compute DMG checksum" → `shasum -a 256`, also
# surfaced as "SHA-256:" in the published release notes). Bump `version` too.
#
# Two backstops prevent shipping the placeholder by accident:
#   1. Scripts/release.sh aborts the release if this file still holds the
#      all-zero sha (the authoritative, publish-blocking guard).
#   2. The Ruby preflight below raises if the all-zero sha reaches `brew`,
#      gated to non-development use so local cask hacking still works.
cask "cliphoard" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # Belt-and-braces: refuse to install/audit a cask that still carries the
  # all-zero placeholder sha256. Gated to non-development runs so `--debug`/local
  # cask editing is unaffected; the real publish-blocking guard lives in
  # Scripts/release.sh. Kept side-effect-free so `ruby -c` / `brew` parsing pass.
  if sha256.to_s == "0000000000000000000000000000000000000000000000000000000000000000" &&
     !Homebrew::EnvConfig.developer?
    odie "Casks/cliphoard.rb still has the all-zero placeholder sha256 — fill in the " \
         "released DMG's sha256 (see Scripts/release.sh / release.yml) before publishing."
  end

  url "https://github.com/AntreasAntoniou/cliphoard/releases/download/v#{version}/Cliphoard-#{version}.dmg",
      verified: "github.com/AntreasAntoniou/cliphoard/"
  name "Cliphoard"
  desc "Fast, private clipboard manager with on-device semantic search"
  homepage "https://github.com/AntreasAntoniou/cliphoard"

  depends_on macos: ">= :ventura"

  app "Cliphoard.app"

  uninstall quit: "ai.axiotic.ditto"

  zap trash: [
    "~/Library/Application Support/Ditto",
    "~/Library/Preferences/ai.axiotic.ditto.plist",
  ]
end
