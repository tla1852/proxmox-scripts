# proxmox-scripts

Scripts d'administration pour Proxmox VE 9.

## create-lxc.sh

Crée un LXC Ubuntu 24.04 de base, identique à chaque fois :

- **Demandé à l'exécution** : nom, nombre de cœurs, RAM, mot de passe utilisateur
- **Réseau** : DHCP sur `vmbr0`
- **Disque** : 8 Go sur `local-lvm`
- **Options** : démarrage au boot, unprivileged, nesting activé
- **Logiciels** : système à jour + curl, docker, git, unzip, python3
- **Utilisateur** : `thibault` (groupes `sudo` + `docker`), root verrouillé

### Utilisation

Sur le nœud Proxmox, en root :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc.sh)
```

Les valeurs par défaut (stockage, taille disque, bridge, template) sont des
variables en tête de script.

## create-lxc-bookorbit.sh

Même base que `create-lxc.sh`, mais installe en plus **BookOrbit**
(portage du script [community-scripts](https://github.com/community-scripts/ProxmoxVE/blob/main/install/bookorbit-install.sh)) :

- PostgreSQL 16 + pgvector (PGDG), base/user `bookorbit`, extensions `uuid-ossp`/`pg_trgm`/`vector`
- Node.js 24 (NodeSource) + uv, build pnpm, env Python `kobo-cloudscraper`
- Dernière release GitHub déployée dans `/opt/bookorbit`, service systemd `bookorbit`
- Disque 12 Go, RAM conseillée ≥ 4096 Mo

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-bookorbit.sh)
```

À la fin, le script affiche l'URL (`http://<ip>:3000`) et le `SETUP_BOOTSTRAP_TOKEN`
(aussi dans `/root/bookorbit-bootstrap.txt` du container) pour le premier setup.

## create-lxc-protonbridge.sh

Même base que `create-lxc.sh`, mais déploie en plus le **Proton Mail Bridge** headless
(image communautaire [`shenxn/protonmail-bridge`](https://github.com/shenxn/protonmail-bridge-docker)),
pour réexposer en IMAP/SMTP local une boîte Proton chiffrée (automatisation n8n, etc.) :

- Image pré-tirée + volume persistant `protonmail`, helper `/root/start-bridge.sh`
- IMAP `143` + SMTP `25` publiés sur l'IP LAN du LXC — **réseau interne uniquement, jamais via reverse proxy**
- Disque 8 Go, RAM 1024 Mo, 1 cœur (le bridge est léger)
- **Prérequis** : plan Proton **payant** (Bridge indisponible en Free)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-protonbridge.sh)
```

⚠️ Le login Proton (compte + 2FA) ne peut pas être scripté : le script imprime un
**runbook** pour l'étape `init` interactive (à faire une fois), qui fournit aussi le
**mot de passe Bridge** (≠ mot de passe Proton) à reporter dans la credential IMAP.

## create-lxc-ludotheque.sh

Même base que `create-lxc.sh`, mais déploie en plus la **Ludothèque**
(gestion de collection de jeux vidéo, [tla1852/ludotheque](https://github.com/tla1852/ludotheque)
en Docker Compose) :

- Clone le repo **privé** dans `/opt/ludotheque`, génère `.env`, `docker compose up -d --build`
- Demande le **PAT GitHub** (lecture, repo privé), `ADMIN_PASSWORD` et les clés API
  (`STEAM_API_KEY`, `IGDB_CLIENT_ID/SECRET`, `RAWG_API_KEY` — toutes optionnelles)
- Le token est retiré du remote git après le clone
- Disque 12 Go (headroom build image), RAM conseillée 2048 Mo

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-ludotheque.sh)
```

À la fin, le script affiche l'URL (`http://<ip>:3000`, login `admin`). Reverse proxy
cible : `ludo.survivalmode.familyds.org`.

## create-lxc-l5.sh

Même base que `create-lxc.sh`, mais déploie en plus **L5**
(hub pro de Lagrange Equilibrium, [tla1852/l5](https://github.com/tla1852/l5) —
Fastify + PostgreSQL 15 en Docker Compose) :

- Clone le repo **privé** dans `/opt/l5`, génère `.env`, `docker compose up -d --build`
  (l'api migre le schéma au démarrage, après le healthcheck PostgreSQL)
- Demande le **PAT GitHub** (lecture, repo privé) et, optionnels, `ANTHROPIC_API_KEY`,
  `PROMETHEUS_URL`, `GRAFANA_URL`. Les secrets internes (`POSTGRES_PASSWORD`,
  `AUTH_SECRET`, `N8N_WEBHOOK_SECRET`, `GRAFANA_WEBHOOK_SECRET`) sont **auto-générés**
  (`openssl rand`) et le token est retiré du remote git après le clone
- `BANK_SOURCE=csv` par défaut : déposer les exports CSV Shine dans `/opt/l5/data/shine`
- Disque 16 Go (image Docker + données PostgreSQL), RAM conseillée 4096 Mo

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-l5.sh)
```

À la fin, le script affiche l'URL de santé (`http://<ip>:3000/health`).

⚠️ L5 contient des données client + finance + identifiants : à exposer **uniquement**
sur le tier Headscale isolé, **jamais en public-facing**.
