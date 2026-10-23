# Homebrew Cask for Cliphoard.
#
# The checksum is computed from the exact signed, notarized and customer-tested
# DMG published on GitHub. Never rebuild it between acceptance and publication.
# Scripts/publish-cask.sh checks the public download before copying this cask
# into a tap; the Ruby guard also refuses an all-zero placeholder.
# A cask in this source repository does not establish a published Homebrew tap.
cask "cliphoard" do
  version "1.0.1"
  sha256 "645d92652d02ddd7200de900abd5c504a2db074b205ae5cb3c6da8e0a75f495d"

  # Belt-and-braces: refuse to install/audit a cask that still carries the
  # all-zero placeholder sha256. Gated to non-development runs so `--debug`/local
  # cask editing is unaffected; the publish-time download check lives in
  # Scripts/publish-cask.sh. Kept side-effect-free so `ruby -c` / `brew` parsing pass.
  if sha256.to_s == "0000000000000000000000000000000000000000000000000000000000000000" &&
     !Homebrew::EnvConfig.developer?
    odie "Casks/cliphoard.rb still has the all-zero placeholder sha256 — fill in the " \
         "released DMG's sha256 (see RELEASING.md) before publishing."
  end

  url "https://github.com/AntreasAntoniou/cliphoard/releases/download/v#{version}/Cliphoard-#{version}.dmg"
  name "Cliphoard"
  desc "Fast, private clipboard manager with on-device semantic search"
  homepage "https://github.com/AntreasAntoniou/cliphoard"

  depends_on macos: :ventura

  app "Cliphoard.app"

  uninstall quit: ["ai.a2-labs.cliphoard", "io.antreas.cliphoard"]

  zap trash: [
    "~/Library/Application Support/Ditto",
    "~/Library/Preferences/ai.a2-labs.cliphoard.plist",
    "~/Library/Preferences/io.antreas.cliphoard.plist",
  ]
end
