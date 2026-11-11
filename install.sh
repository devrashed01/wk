#!/bin/sh
# Install Wk (menu-bar app + `wk` CLI) from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/devrashed01/wk/main/install.sh | sh
# Options (env): WK_VERSION=0.1.1 to pin a version, WK_APP_DIR=~/Applications, WK_BIN_DIR=~/.local/bin
set -eu

REPO="devrashed01/wk"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Wk is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "Wk needs macOS 14 or later (you have $(sw_vers -productVersion))."

version="${WK_VERSION:-}"
if [ -z "$version" ]; then
  version=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
  [ -n "$version" ] || die "could not find the latest release."
fi
version="${version#v}"

app_dir="${WK_APP_DIR:-/Applications}"
if [ ! -w "$app_dir" ]; then app_dir="$HOME/Applications"; fi
mkdir -p "$app_dir"

if [ -n "${WK_BIN_DIR:-}" ]; then bin_dir="$WK_BIN_DIR"
elif [ -w /opt/homebrew/bin ]; then bin_dir=/opt/homebrew/bin
elif [ -w /usr/local/bin ]; then bin_dir=/usr/local/bin
else bin_dir="$HOME/.local/bin"; fi
mkdir -p "$bin_dir"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$REPO/releases/download/v$version"
zip="Wk-$version-macos.zip"

say "Downloading Wk $version"
curl -fL --progress-bar -o "$tmp/$zip" "$base/$zip" || die "download failed: $base/$zip"
curl -fsSL -o "$tmp/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || die "could not download checksums."
(cd "$tmp" && grep " $zip\$" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null) || die "checksum mismatch for $zip."

ditto -x -k "$tmp/$zip" "$tmp/x"
[ -d "$tmp/x/Wk.app" ] || die "archive does not contain Wk.app."

if pgrep -x Wk >/dev/null 2>&1; then say "Quitting running Wk"; pkill -x Wk || true; sleep 1; fi
rm -rf "$app_dir/Wk.app"
ditto "$tmp/x/Wk.app" "$app_dir/Wk.app"
xattr -dr com.apple.quarantine "$app_dir/Wk.app" 2>/dev/null || true
ln -sf "$app_dir/Wk.app/Contents/Resources/wk" "$bin_dir/wk"

say "Installed $app_dir/Wk.app"
say "Linked $bin_dir/wk"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) printf '   add it to your PATH:  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc\n' "$bin_dir" ;;
esac

open "$app_dir/Wk.app"
say "Wk is running in the menu bar. Press ⌥Space to open it."
