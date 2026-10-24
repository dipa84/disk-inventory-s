#!/bin/zsh
# Copyright (C) 2026 Riccardo Di Paola. SPDX-License-Identifier: GPL-3.0-or-later
# Builds the app and packs it for download: .build/dist/Disk-Inventory-S-<version>.zip and .dmg
# (the disk image has the app and a link to Applications, to drag it there).
set -e
cd "${0:A:h}/.."
tools/build-app.sh
version=$(cat VERSION)
name="Disk Inventory S"
app=".build/$name.app"
dist=.build/dist
rm -rf $dist
mkdir -p $dist/dmg
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/Disk-Inventory-S-$version.zip"
cp -R "$app" $dist/dmg/
ln -s /Applications $dist/dmg/Applications
hdiutil create -quiet -volname "$name $version" -srcfolder $dist/dmg -fs HFS+ -format UDZO "$dist/Disk-Inventory-S-$version.dmg"
rm -rf $dist/dmg
shasum -a 256 $dist/*.zip $dist/*.dmg
