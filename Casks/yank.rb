# Homebrew Cask for Yank.
#
# Publish this from a tap repo (e.g. github.com/AntreasAntoniou/homebrew-tap)
# so users can:  brew install --cask antreasantoniou/tap/yank
# Update `version` + `sha256` on each release (the CI prints the DMG sha256).
cask "yank" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/AntreasAntoniou/yank/releases/download/v#{version}/Yank-#{version}.dmg",
      verified: "github.com/AntreasAntoniou/yank/"
  name "Yank"
  desc "Fast, private clipboard manager with on-device semantic search"
  homepage "https://github.com/AntreasAntoniou/yank"

  depends_on macos: ">= :ventura"

  app "Yank.app"

  uninstall quit: "ai.axiotic.ditto"

  zap trash: [
    "~/Library/Application Support/Ditto",
    "~/Library/Preferences/ai.axiotic.ditto.plist",
  ]
end
