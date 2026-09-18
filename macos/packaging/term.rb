cask "term" do
  version "0.1.0"
  sha256 "329b30a4c12d7ba5200cbd83456929d073079ef570c84928c6751a4632525db1"

  url "https://github.com/dededemahendra/term/releases/download/v#{version}/Term-#{version}.dmg"
  name "Term"
  desc "Light and fast terminal emulator"
  homepage "https://github.com/dededemahendra/term"

  depends_on macos: ">= :sonoma"

  app "Term.app"

  zap trash: "~/.config/term"
end
