#!/bin/bash
# Writes the Homebrew cask for a built release to dist/wk.rb (run after `make release`).
#   scripts/cask.sh 0.2.6
set -euo pipefail
version="${1:?usage: scripts/cask.sh <version>}"
sha="$(awk -v f="Wk-$version-macos.zip" '$2 == f { print $1 }' dist/SHA256SUMS.txt)"
[ -n "$sha" ] || { echo "no checksum for Wk-$version-macos.zip in dist/SHA256SUMS.txt" >&2; exit 1; }
cat > dist/wk.rb <<RUBY
cask "wk" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/devrashed01/wk/releases/download/v#{version}/Wk-#{version}-macos.zip"
  name "Wk"
  desc "Switcher for git worktrees and Claude Code sessions, built on cmux"
  homepage "https://devrashed01.github.io/wk/"

  depends_on macos: ">= :sonoma"

  app "Wk.app"
  binary "#{appdir}/Wk.app/Contents/Resources/wk"

  # The app is signed but not notarized; without this macOS refuses to open it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Wk.app"]
  end

  uninstall quit: "com.devrashed01.wk"

  zap trash: [
    "~/.cache/wk",
    "~/.config/wk",
    "~/.local/state/wk",
  ]
end
RUBY
echo "Wrote dist/wk.rb"
