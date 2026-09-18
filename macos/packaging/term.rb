cask "term" do
  version "0.1.1"
  sha256 "83f2ee9c90d8f09783b4f3e778280b74394e969ad0753324401ea5de9e7776b3"

  url "https://github.com/dededemahendra/term/releases/download/v#{version}/Term-#{version}.dmg"
  name "Term"
  desc "Light and fast terminal emulator"
  homepage "https://github.com/dededemahendra/term"

  depends_on macos: :sonoma

  app "Term.app"

  zap trash: "~/.config/term"
end
