# Template: replace the sha256, url and homepage before publishing a release.
cask "term" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_DMG"

  url "https://example.invalid/term/releases/download/v#{version}/Term-#{version}.dmg"
  name "Term"
  desc "Light and fast terminal emulator"
  homepage "https://example.invalid/term"

  depends_on macos: ">= :sonoma"

  app "Term.app"

  zap trash: "~/.config/term"
end
