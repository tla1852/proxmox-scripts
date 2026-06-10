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
