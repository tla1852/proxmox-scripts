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

## update-lxc-bookorbit.sh

Met à jour BookOrbit dans un CT existant vers la dernière release GitHub
(rebuild pnpm + relance du service ; migrations DB via `ExecStartPre`). Préserve
`.env` (secrets), les dossiers data et PostgreSQL. Idempotent (ne fait rien si
déjà à jour) et fait un snapshot LXC avant MAJ par défaut.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/update-lxc-bookorbit.sh) <VMID>
```

Options : `--force` (rebuild même si à jour), `--no-snapshot` (saute le snapshot).

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

## create-lxc-ferroxide.sh

Même base que `create-lxc.sh`, mais build **ferroxide**
([`acheong08/ferroxide`](https://github.com/acheong08/ferroxide)), pont tiers qui
réexpose l'agenda **Proton en CalDAV** (port `8081`) — la source du *miroir
calendrier* de [tla1852/l5](https://github.com/tla1852/l5) :

- Binaire Go (`go install …/ferroxide@latest` → `/usr/local/bin/ferroxide`), pas
  d'image Docker officielle
- Dépose un service systemd `ferroxide-caldav` **prêt mais non démarré** (l'`auth`
  Proton interactive + 2FA doit précéder ; non scriptable)
- Disque 8 Go, RAM 1024 Mo, 1 cœur (léger). Distinct du **Proton Mail Bridge**
  (`create-lxc-protonbridge.sh`, qui ne fait qu'IMAP/SMTP)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-ferroxide.sh)
```

⚠️ Le login Proton (compte + 2FA) ne peut pas être scripté : le script imprime un
**runbook** pour `ferroxide auth` (qui fournit le **bridge password** = mot de passe
CalDAV), le démarrage du service et la vérification PROPFIND. Tier isolé, réseau
interne uniquement — jamais public-facing.

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

## create-lxc-headscale.sh

Même base que `create-lxc.sh`, mais déploie en plus **Headscale**, le plan de
contrôle Tailscale self-hosted (plan privé du homelab — cf.
[tla1852/homelab-secu](https://github.com/tla1852/homelab-secu), phase 2) :

- Image Docker **épinglée** (`headscale/headscale:0.23.0`) ; la config est dérivée
  du `config-example.yaml` de cette version exacte (zéro dérive de schéma), puis
  patchée : `server_url`, `listen_addr=0.0.0.0:8080`, `base_domain`
- Demande le domaine public (`server_url`, défaut `headscale.survivalmode.familyds.org`)
  et le `base_domain` MagicDNS interne (défaut `ts.lan`)
- Crée l'utilisateur tailnet `thibault` + une pré-auth key (réutilisable 24h) et
  imprime le **runbook d'enrôlement** (appareils + paquet Tailscale du NAS Synology)
- Disque 8 Go, RAM 1024 Mo, 1 cœur (SQLite, plan de contrôle léger)
- À construire **avant** l'edge Caddy (qui reverse-proxie vers son `:8080`)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-headscale.sh)
```

⚠️ L'enrôlement n'aboutit qu'une fois l'edge Caddy en place (HTTPS public sur
`server_url`) + DNS + forwards routeur. Voir le runbook imprimé.

## create-lxc-caddy.sh

Même base que `create-lxc.sh`, mais déploie en plus **Caddy en edge** — la porte
d'entrée publique HTTPS du homelab (cf. homelab-secu, phase 1) :

- Image Docker `caddy:2.8`, reverse proxy + Let's Encrypt **HTTP-01**
- Demande : email ACME, domaine + upstream Jellyfin (seul service applicatif
  public), domaine + upstream du plan de contrôle Headscale
- Génère le `Caddyfile` (vhosts Jellyfin + Headscale) et le `docker-compose.yml`,
  publie 80/443 (TCP) + 443/UDP
- Disque 8 Go, RAM 1024 Mo, 1 cœur
- À construire **après** le LXC Headscale (il faut son IP). Vit d'abord sur
  `vmbr0` ; bascule en **VLAN DMZ isolé + bouncer CrowdSec + geoblock** en phase 4
  (build `xcaddy` custom, hors périmètre v1)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-caddy.sh)
```

**Prérequis réseau** : forward routeur 80/443 → IP de ce LXC (et plus vers le
Synology) ; DNS `survivalmode.familyds.org` + `headscale.survivalmode.familyds.org`
résolvant vers l'IP publique maison. Runbook imprimé en fin de script.

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

## create-lxc-supervision.sh

Même base que `create-lxc.sh`, mais déploie en plus la **stack de supervision**
(Prometheus + Grafana + pve-exporter + blackbox-exporter en Docker Compose) —
le moteur du module Supervision de L5. Voir
[`homelab/supervision/`](homelab/supervision/) pour l'architecture complète.

- Installe `prometheus-node-exporter` **sur l'hôte PVE** (port 9100)
- Crée l'utilisateur API `monitoring@pve` + token `supervision` (rôle **PVEAuditor**,
  lecture seule, token régénéré à chaque run) pour pve-exporter
- Clone ce repo dans `/opt/proxmox-scripts`, génère `.env` + `secrets/`,
  `docker compose up -d` depuis `homelab/supervision/`
- Demande : mot de passe admin Grafana, secret webhook L5
  (`GRAFANA_WEBHOOK_SECRET` de `/opt/l5/.env`), mot de passe de scrape GCP
- GCP : métriques Cloud Monitoring via un `stackdriver-exporter` hébergé
  **dans Cloud Run** (pas de clé SA, org policy) — scrapé en HTTPS + basic auth
- Alerting : contact point + 5 règles provisionnés → webhook L5 → page Supervision
- Disque 16 Go (TSDB 90 j), RAM conseillée 2048 Mo

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-supervision.sh)
```

À la fin, le script affiche les URLs Prometheus/Grafana et les étapes post-install
(vhost `grafana.ts.tlagrange.pro`, `PROMETHEUS_URL`/`GRAFANA_URL` dans L5, dashboards).
