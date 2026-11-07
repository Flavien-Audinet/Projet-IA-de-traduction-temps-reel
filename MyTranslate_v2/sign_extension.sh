#!/bin/zsh
# Signe l'extension Firefox en mode « non listé » (privée, pas publiée sur addons.mozilla.org).
#
# 1. Crée tes clés (gratuit) : https://addons.mozilla.org/developers/addon/api/key/
#    → « JWT issuer » (user:12345:678) et « JWT secret »
# 2. Lance :  AMO_JWT_ISSUER='user:…' AMO_JWT_SECRET='…' ./sign_extension.sh
# 3. Ouvre le fichier .xpi produit dans Firefox (glisser-déposer dans une fenêtre) → Ajouter.
#
# Pour chaque nouvelle version : augmenter "version" dans Extension/manifest.json, puis relancer.
set -euo pipefail
cd "$(dirname "$0")"
: "${AMO_JWT_ISSUER:?définis AMO_JWT_ISSUER (voir l'en-tête du script)}"
: "${AMO_JWT_SECRET:?définis AMO_JWT_SECRET (voir l'en-tête du script)}"
mkdir -p build/extension
npx --yes web-ext@latest sign --source-dir Extension --artifacts-dir build/extension \
  --channel unlisted --api-key "$AMO_JWT_ISSUER" --api-secret "$AMO_JWT_SECRET"
echo "✓ Extension signée :"
ls -1 build/extension/*.xpi
