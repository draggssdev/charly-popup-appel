#!/usr/bin/env bash
#
# charly-popup-appel — installeur pour Mac de consultant
#
# Usage : curl -fsSL https://raw.githubusercontent.com/charly/popup-appel/main/install.sh | bash
#
# Aucune clé à saisir. La logique métier et la clé API Jarvi sont
# server-side. Le seul secret embarqué dans call_watcher.lua est le
# Bearer token partagé.

set -euo pipefail

CALL_WATCHER_URL="https://raw.githubusercontent.com/charly/popup-appel/main/call_watcher.lua"

echo "→ Installation popup-appel"

# 1. Hammerspoon
if ! [ -d "/Applications/Hammerspoon.app" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "✗ Homebrew n'est pas installé. Installer depuis https://brew.sh/ puis relancer."
        exit 1
    fi
    echo "  Installation de Hammerspoon via Homebrew…"
    brew install --cask hammerspoon
else
    echo "  Hammerspoon déjà installé ✓"
fi

# 2. ~/.hammerspoon
mkdir -p ~/.hammerspoon

# 3. Télécharger la dernière version du watcher
echo "  Téléchargement de call_watcher.lua…"
curl -fsSL "$CALL_WATCHER_URL" -o ~/.hammerspoon/call_watcher.lua

# 4. Activer dans init.lua si pas déjà fait
if ! grep -q 'call_watcher' ~/.hammerspoon/init.lua 2>/dev/null; then
    echo '' >> ~/.hammerspoon/init.lua
    echo '-- charly-popup-appel' >> ~/.hammerspoon/init.lua
    echo 'popupAppel = require("call_watcher")' >> ~/.hammerspoon/init.lua
fi

# 5. Lancer Hammerspoon
open -a Hammerspoon

cat <<'EOF'

✅ Installation terminée.

ÉTAPES MANUELLES (1 fois) :

  1. Réglages système → Confidentialité et sécurité
     → Accessibilité → cocher "Hammerspoon"

  2. Réglages système → Confidentialité et sécurité
     → Accès complet au disque → cocher "Hammerspoon"
     ⚠ Indispensable pour lire l'historique d'appels.

  3. Quitter et relancer Hammerspoon.

  4. Vérifier que Continuity est actif :
     - iPhone : Réglages → Téléphone → Appels sur d'autres appareils
       → activer + cocher ce Mac
     - Mac : FaceTime → Réglages → Général
       → cocher "Appels depuis l'iPhone"

TEST :
  Cmd+Option+P pendant que Hammerspoon tourne
  → une popup doit apparaître en haut-droite avec un numéro de test.

DEBUG :
  Barre de menu Hammerspoon → Console
  → cherche les lignes [popup-appel].

MISE À JOUR :
  Relance ce même script (`curl … | bash`) pour récupérer la
  dernière version de call_watcher.lua.

EOF
