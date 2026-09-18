cask "term" do
  version "0.1.0"
  sha256 "59ebeeef434b14c4dd76527185859bc03c8abc71ff9982c451d5deaefd202f8d"

  url "https://github.com/dededemahendra/term/releases/download/v#{version}/Term-#{version}.dmg"
  name "Term"
  desc "Light and fast terminal emulator"
  homepage "https://github.com/dededemahendra/term"

  depends_on macos: ">= :sonoma"

  app "Term.app"

  zap trash: "~/.config/term"
end
