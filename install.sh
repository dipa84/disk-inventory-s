#!/bin/zsh
# Copyright (C) 2026 Riccardo Di Paola. SPDX-License-Identifier: GPL-3.0-or-later
# Installs the latest Disk Inventory S into /Applications:
#   curl -fsSL https://raw.githubusercontent.com/dipa84/disk-inventory-s/main/install.sh | zsh
# Files downloaded with curl are not quarantined, so macOS opens the app without asking.
set -e
repo=dipa84/disk-inventory-s
url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
[[ -n "$url" ]] || { echo "no release found at github.com/$repo" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $url"
curl -fL --progress-bar -o "$tmp/dis.zip" "$url"
rm -rf "/Applications/Disk Inventory S.app"
ditto -x -k "$tmp/dis.zip" /Applications
echo "Installed: /Applications/Disk Inventory S.app"
