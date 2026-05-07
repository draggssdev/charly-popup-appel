#!/usr/bin/env bash
#
# charly-popup-appel — installeur Mac pour consultants
#
# Usage :
#   curl -fsSL https://raw.githubusercontent.com/draggssdev/charly-popup-appel/master/install.sh | bash
#
# Le script demande le bearer token (à obtenir auprès de Lucas/Charly)
# et le stocke dans macOS Keychain (chiffré). Le call_watcher.lua le lit
# depuis le Keychain au démarrage, donc le token n'est jamais sur le disque
# en clair.

set -euo pipefail

CALL_WATCHER_URL="https://raw.githubusercontent.com/draggssdev/charly-popup-appel/master/call_watcher.lua"
KEYCHAIN_SERVICE="charly-popup-appel"

echo ""
echo "════════════════════════════════════════════════════"
echo "  Installation popup-appel — Charly"
echo "════════════════════════════════════════════════════"
echo ""

# 1. Hammerspoon
if ! [ -d "/Applications/Hammerspoon.app" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "✗ Homebrew n'est pas installé."
        echo "  Installe-le depuis https://brew.sh/ puis relance ce script."
        exit 1
    fi
    echo "→ Installation de Hammerspoon via Homebrew…"
    brew install --cask hammerspoon
else
    echo "✓ Hammerspoon déjà installé"
fi

# 2. Demander le bearer token
echo ""
echo "Colle le bearer token Charly que t'a transmis l'admin"
echo "(la saisie est cachée pour des raisons de sécurité) :"
echo ""
# /dev/tty force la lecture depuis le clavier même quand le script tourne
# via 'curl | bash' (sinon read lit depuis le pipe curl, pas le clavier).
read -s -p "  Token : " TOKEN < /dev/tty
echo ""
if [ -z "$TOKEN" ]; then
    echo "✗ Token vide, annulation."
    exit 1
fi

# 3. Stocker dans Keychain (chiffré, lisible uniquement par cet utilisateur)
echo "→ Sauvegarde du token dans macOS Keychain…"
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" 2>/dev/null || true
security add-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$USER" \
    -w "$TOKEN" \
    -T /Applications/Hammerspoon.app \
    -T /usr/bin/security
echo "✓ Token sauvegardé"

# 4. Préparer ~/.hammerspoon
mkdir -p ~/.hammerspoon

# 5. Télécharger la dernière version du watcher
echo "→ Téléchargement de call_watcher.lua…"
curl -fsSL "$CALL_WATCHER_URL" -o ~/.hammerspoon/call_watcher.lua
echo "✓ call_watcher.lua installé"

# 6. Activer dans init.lua si pas déjà fait
if ! grep -q 'call_watcher' ~/.hammerspoon/init.lua 2>/dev/null; then
    echo '' >> ~/.hammerspoon/init.lua
    echo '-- charly-popup-appel' >> ~/.hammerspoon/init.lua
    echo 'popupAppel = require("call_watcher")' >> ~/.hammerspoon/init.lua
    echo "✓ Activé dans ~/.hammerspoon/init.lua"
fi

# 7. Lancer Hammerspoon
open -a Hammerspoon

# 8. Instructions finales
cat <<'EOF'

════════════════════════════════════════════════════
  ✅ Installation terminée.

  ÉTAPES MANUELLES (à faire 1 seule fois) :

  1. Réglages système → Confidentialité et sécurité
     → Accessibilité → cocher "Hammerspoon"

  2. Réglages système → Confidentialité et sécurité
     → Accès complet au disque → cocher "Hammerspoon"
     ⚠ Indispensable pour lire l'historique d'appels.

  3. Quitter Hammerspoon (icône en haut à droite → Quit)
     puis le relancer.

  4. Vérifier que Continuity est actif :
     - iPhone : Réglages → Téléphone
       → "Appels sur d'autres appareils" → activer + cocher ce Mac
     - Mac : FaceTime → Réglages → Général
       → cocher "Appels depuis l'iPhone"

  TEST :
     ⌘+⌥+P (Cmd+Option+P) doit afficher une popup test.

  MISE À JOUR :
     Relance la commande curl pour récupérer la dernière version.

  CHANGER DE TOKEN :
     security delete-generic-password -s charly-popup-appel -a "$USER"
     puis relance ce script.
════════════════════════════════════════════════════

EOF
