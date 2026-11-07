#!/bin/zsh
# Compile MyTranslate.app sans Xcode (Command Line Tools suffisent).
#   ./build.sh            -> build/MyTranslate.app
#   ./build.sh install    -> copie aussi dans /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MyTranslate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# On compile depuis une copie locale temporaire (utile si le projet est sur un partage réseau :
# évite les erreurs « file was modified during the build » dues aux horodatages réseau).
SRC=$(mktemp -d /tmp/mytranslate-src.XXXXXX)
trap 'rm -rf "$SRC"' EXIT
cp -R Sources "$SRC/"

echo "→ Compilation Swift"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx15.0" \
  "$SRC"/Sources/**/*.swift \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit -framework Vision \
  -framework NaturalLanguage -framework Translation -framework Carbon -framework CoreMedia -framework Network -framework CoreAudio -framework AudioToolbox \
  -o "$APP/Contents/MacOS/MyTranslate"

# Identifiant de l'app : local.<compte Mac> par défaut (les autorisations macOS restent valables d'une
# compilation à l'autre), ou BUNDLE_PREFIX=… ./build.sh pour une version à distribuer.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-local.$(id -un)}"
sed "s/__BUNDLE_PREFIX__/$BUNDLE_PREFIX/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Engine/mt_server.py Engine/dub_server.py Engine/dub_ahead.py Engine/local_guard.py "$APP/Contents/Resources/"
# Signature : certificat local « MyTranslate Dev » s'il existe (l'autorisation d'enregistrement d'écran
# reste alors valable d'une version à l'autre), sinon signature ad hoc (autorisation à redonner après
# chaque compilation). Création du certificat : Trousseaux d'accès › Assistant de certification ›
# Créer un certificat › nom « MyTranslate Dev », Racine auto-signée, Signature de code.
if security find-identity -p codesigning 2>/dev/null | grep -q "MyTranslate Dev"; then
  codesign --force --sign "MyTranslate Dev" "$APP" >/dev/null 2>&1 && echo "→ signé avec « MyTranslate Dev »"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "→ signature ad hoc (pas de certificat « MyTranslate Dev »)"
fi
echo "✓ $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x MyTranslate 2>/dev/null && sleep 1 || true
  rm -rf /Applications/MyTranslate.app
  cp -R "$APP" /Applications/
  echo "✓ installé dans /Applications/MyTranslate.app"
fi
