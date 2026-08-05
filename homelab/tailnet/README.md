# Tailnet — enrôlement de LXC

`enroll-lxc.sh` met un LXC Proxmox sur le tailnet Headscale (plage CGNAT
`100.64.0.0/10`, tunnel WireGuard, **rien d'exposé sur internet**).

Utile pour un LXC **sans interface web** qu'on veut joindre en SSH/RDP depuis
n'importe quel réseau (ex. `claude-dev`).

## Usage — depuis l'hôte Proxmox

```bash
curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/tailnet/enroll-lxc.sh -o /tmp/enroll-lxc.sh
bash /tmp/enroll-lxc.sh claude-dev
```

Accepte un CTID (`bash /tmp/enroll-lxc.sh 123`) ou un hostname.

> ⚠️ Le script **redémarre le LXC** si `/dev/net/tun` manque (nécessaire pour
> WireGuard en conteneur non-privilégié). Toute session ouverte dans le LXC est
> coupée — d'où l'exécution depuis l'hôte.

Idempotent : relançable sans risque (skip du reboot si tun déjà là, skip de
l'install si Tailscale déjà présent).

## Ce que ça fait

1. `lxc.cgroup2.devices.allow` + `lxc.mount.entry` pour `/dev/net/tun`, reboot
2. clé de pré-auth Headscale (CT 145, réutilisable 24 h)
3. install Tailscale + `systemctl enable --now tailscaled`
4. `tailscale up --login-server https://headscale.survivalmode.familyds.org`
5. `sshd` activé, `headscale nodes list` affiché, IP tailnet rappelée

`--accept-dns=false` : le LXC garde son resolver, on ne veut pas que MagicDNS
écrase `/etc/resolv.conf` sur un serveur.

## Révoquer

```bash
pct exec 145 -- docker exec headscale headscale nodes delete -i <id>
```

Procédure détaillée dans L5 : *Homelab / Tailscale / Enrôler un LXC sur le tailnet*.
