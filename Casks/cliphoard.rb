# Homebrew cask for the exact signed, stapled Cliphoard 1.0.4 build 29 ZIP.
# Publish only after the public archive checksum has been verified.
cask "cliphoard" do
  version "1.0.4"
  sha256 "d3afb2a1613e1cc79829c25e6dc8b7e890cfe018945dfb47cfb50d8cd3e6ca06"

  # Refuse a placeholder checksum.
  if sha256.to_s == "0000000000000000000000000000000000000000000000000000000000000000" &&
     !Homebrew::EnvConfig.developer?
    odie "Casks/cliphoard.rb still has the all-zero placeholder sha256 — fill in the " \
         "released archive's sha256 (see RELEASING.md) before publishing."
  end

  url "https://github.com/AntreasAntoniou/cliphoard/releases/download/direct-v1.0.4-build29/Cliphoard-1.0.4-Direct-build29.zip"
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
