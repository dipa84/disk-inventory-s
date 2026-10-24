#!/bin/zsh
# Builds Disk Inventory S.app: the window, the helper for system folders, the icon and the
# translations.
#
# Signing: with the local certificate "Disk Inventory S - Riccardo Di Paola" when it is in the
# keychain (see tools/make-certificate.sh), otherwise ad hoc. It matters for privacy permissions:
# macOS remembers them by the app's designated requirement. Ad hoc, that is the hash of the binary,
# so every build looks like a new app and the permissions are asked again; with the certificate it
# is the bundle identifier plus the certificate, which stay the same across builds.
#
# usage: tools/build-app.sh           → .build/Disk Inventory S.app
#        tools/build-app.sh --install → also into /Applications
set -e
cd "${0:A:h}/.."
# translations: stops if a string is not translated
python3 -I tools/translations.py
swift build -c release --product DiskInventoryS
# the helper for system folders (the app runs it with the administrator password)
swift build -c release --product dis-cli
version=$(cat VERSION)
name="Disk Inventory S"
app=".build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/DiskInventoryS "$app/Contents/MacOS/"
cp .build/release/dis-cli "$app/Contents/MacOS/"
cp assets/macos/DiskInventoryS.icns "$app/Contents/Resources/"
cp -R assets/macos/Localizations/*.lproj "$app/Contents/Resources/"
sed "s/@VERSION@/$version/g" assets/macos/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
identity="Disk Inventory S - Riccardo Di Paola"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  codesign --force --deep --sign "$identity" "$app"
else
  echo "warning: no \"$identity\" certificate, signing ad hoc (permissions will be asked again)" >&2
  codesign --force --deep --sign - "$app"
fi
if [[ "$1" == "--install" ]]; then
  # the earlier working name
  rm -rf /Applications/Inventario.app
  rm -rf "/Applications/$name.app"
  cp -R "$app" /Applications/
  app="/Applications/$name.app"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
