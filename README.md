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
