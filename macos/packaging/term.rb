cask "term" do
  version "0.1.1"
  sha256 "8222b49de14941c9a5b338e9f46139ce95a06d1330046175538adbfd2131fc21"

  url "https://github.com/dededemahendra/term/releases/download/v#{version}/Term-#{version}.dmg"
  name "Term"
  desc "Light and fast terminal emulator"
  homepage "https://github.com/dededemahendra/term"

  depends_on macos: ">= :sonoma"

  app "Term.app"

  zap trash: "~/.config/term"
end
