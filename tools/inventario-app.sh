#!/bin/zsh
# Disk Inventory S.app: compila la finestra e la mette in un pacchetto con l'icona. Firmato «ad hoc»
# (per questo Mac): per darlo ad altri serve la firma di uno sviluppatore Apple.
#
# uso: tools/inventario-app.sh            → .build/Disk Inventory S.app
#      tools/inventario-app.sh --installa → anche in /Applications
set -e
cd "${0:A:h}/.."
# le traduzioni: si ferma se una frase non è tradotta
python3 -I tools/traduzioni.py
swift build -c release --product Inventario
# il programma d'aiuto per le cartelle di sistema (lo lancia l'app, con la password)
swift build -c release --product inventario-cli
version=$(cat VERSION)
name="Disk Inventory S"
app=".build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Inventario "$app/Contents/MacOS/"
cp .build/release/inventario-cli "$app/Contents/MacOS/"
cp assets/macos/Inventario.icns "$app/Contents/Resources/"
cp -R assets/macos/Localizations/*.lproj "$app/Contents/Resources/"
sed "s/@VERSIONE@/$version/g" assets/macos/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$app"
if [[ "$1" == "--installa" ]]; then
  # il nome di lavoro di prima
  rm -rf /Applications/Inventario.app
  rm -rf "/Applications/$name.app"
  cp -R "$app" /Applications/
  app="/Applications/$name.app"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
