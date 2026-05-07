# charly-popup-appel — client Mac (Hammerspoon)

Quand un appel arrive sur ton iPhone et est relayé sur ton Mac via
Continuity, une popup s'affiche en haut-droite avec :

- **Nom + prénom**
- Titre · entreprise (si renseignés dans Jarvi)
- **Email**
- Téléphone
- **Tous les projets** rattachés (jusqu'à 4) — chacun cliquable
- Dernière action (type · date)
- Un bouton **"Voir la fiche profil"** (ou "Ouvrir fiche client" si c'est un
  contact CRM)

Cliquer un projet ouvre dans Chrome :
`https://beta.jarvi.tech/#/ats/projects/<uuid_projet>/profiles/<uuid_profil>`

Cliquer le bouton ouvre :
- Candidat : `https://beta.jarvi.tech/#/ats/profiles/<uuid_profil>`
- Client : `https://beta.jarvi.tech/#/crm/profiles/<uuid_profil>`

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/charly/popup-appel/main/install.sh | bash
```

Puis suivre les étapes affichées (autorisations Hammerspoon dans Réglages
système).

## Comment ça marche

```
┌─────────┐   ┌────────────────┐   ┌────────────────┐
│ iPhone  │──▶│ Mac            │──▶│ Hammerspoon    │
│ (appel) │   │ CallHistory.db │   │ - watcher SQL  │
└─────────┘   └────────────────┘   │ - popup webview│──▶ Render
                                   │ - clic→Chrome  │    /lookup
                                   └────────────────┘
```

- **Watcher** : `hs.pathwatcher` surveille
  `~/Library/Application Support/CallHistoryDB/` ; à chaque écriture, on lit
  la dernière ligne de `ZCALLRECORD` où `ZORIGINATED = 0` (appel entrant).
- **Lookup** : appel HTTPS au serveur Render avec `Authorization: Bearer …`,
  qui renvoie un JSON déjà prêt (nom, email, projets avec URLs construites,
  dernière action).
- **Popup** : webview Hammerspoon HTML/CSS, position fixe haut-droite,
  auto-fermeture 25s.
- **Clic** : `policyCallback` intercepte la navigation, vérifie que l'URL
  est sur un domaine autorisé (`beta.jarvi.tech`, `app.jarvi.tech`),
  et lance `open -a 'Google Chrome' <url>`.

## Ce qui est dans ce fichier (et ce qui n'y est PAS)

✅ Détection appel · rendu popup · ouverture Chrome
❌ Logique Jarvi (query, format URL, normalisation numéro) → côté serveur
❌ Clé API Jarvi → côté serveur uniquement

→ Si Jarvi modifie son schema, **on n'update pas ce fichier** : seul le
serveur change.

## Test

- **Test manuel sans appel réel** : `Cmd+Option+P`. Ça déclenche un lookup
  sur un numéro de test (à modifier dans `call_watcher.lua` ligne du
  hotkey si tu veux ton propre numéro).
- **Test depuis la console Hammerspoon** :
  ```lua
  popupAppel.test("+33676561341")
  ```
- **Test réel** : reçois un appel sur l'iPhone, popup ~1-3s après le début
  de la sonnerie.

## Debug

- Logs : barre de menu Hammerspoon → **Console**, cherche `[popup-appel]`.
- Vérifier que le serveur répond :
  ```bash
  curl https://charly-popup-appel.onrender.com/health
  ```
- Vérifier la lecture SQLite à la main :
  ```bash
  sqlite3 ~/Library/Application\ Support/CallHistoryDB/CallHistory.storedata \
      "SELECT ZADDRESS, ZDATE, ZORIGINATED FROM ZCALLRECORD ORDER BY ZDATE DESC LIMIT 3;"
  ```

## Mise à jour

Relance le `install.sh` : il ré-télécharge `call_watcher.lua`. Puis dans
Hammerspoon → barre de menu → **Reload Config**.

## Limitations connues

- **Latence 1-3 s** : Apple écrit dans la base au moment où l'appel commence
  à sonner sur le Mac, pas avant.
- **Free tier Render** : si le serveur dort (15 min sans trafic), première
  popup peut prendre ~30 s. Passer en Starter ($7/mois) pour always-on.
- **Pas d'identification sur l'écran natif iPhone** (nécessiterait une app
  iOS sur l'App Store via CallKit Directory Extension).
- **Numéro non trouvé dans Jarvi** : popup affichée avec juste le numéro et
  "Inconnu dans Jarvi".
