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

- Image **patchée** (`shenxn/protonmail-bridge` + `libfido2-1`) buildée sur place, volume persistant `protonmail`, helper `/root/start-bridge.sh`
- IMAP `143` publié sur l'IP LAN du LXC — **réseau interne uniquement, jamais via reverse proxy**. SMTP `25` non publié (inutile ici, n8n lit l'IMAP ; port souvent déjà pris par un MTA local) — décommenter dans le helper si l'envoi est requis.
- Disque 8 Go, RAM 1024 Mo, 1 cœur (le bridge est léger)
- **Prérequis** : plan Proton **payant** (Bridge indisponible en Free)

> Pourquoi libfido2 : après l'`init`, le bridge s'auto-update vers une version qui dépend de `libfido2.so.1`, absente de l'image brute → crash `cannot open shared object file`. L'image patchée corrige ça.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-protonbridge.sh)
```

⚠️ Le login Proton (compte + 2FA) ne peut pas être scripté : le script imprime un
**runbook** pour l'étape `init` interactive (à faire une fois), qui fournit aussi le
**mot de passe Bridge** (≠ mot de passe Proton) à reporter dans la credential IMAP.
