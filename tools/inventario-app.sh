#!/bin/zsh
# Inventario.app: compila la finestra e la mette in un pacchetto con l'icona. Firmato «ad hoc»
# (per questo Mac): per darlo ad altri serve la firma di uno sviluppatore Apple.
#
# uso: tools/inventario-app.sh            → .build/Inventario.app
#      tools/inventario-app.sh --installa → anche in /Applications
set -e
cd "${0:A:h}/.."
swift build -c release --product Inventario
version=$(cat VERSION)
app=.build/Inventario.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp .build/release/Inventario $app/Contents/MacOS/
[[ -f assets/macos/Inventario.icns ]] && cp assets/macos/Inventario.icns $app/Contents/Resources/
sed "s/@VERSIONE@/$version/g" assets/macos/Info.plist > $app/Contents/Info.plist
plutil -lint $app/Contents/Info.plist >/dev/null
codesign --force --deep --sign - $app
if [[ "$1" == "--installa" ]]; then
  rm -rf /Applications/Inventario.app
  cp -R $app /Applications/
  app=/Applications/Inventario.app
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $app
echo $app
