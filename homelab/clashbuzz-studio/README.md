# ClashBuzz Studio — LXC dédié (tailnet only)

Web UI **admin** de la bibliothèque de playlists ClashBuzz (repo privé
`tla1852/blindtest`, app `apps/studio`) : génération automatique des playlists
Deezer/YouTube depuis les playlists Spotify du compte dédié, gestion des
entrées `library_playlists` (Supabase), stockage des secrets des comptes
dédiés. Doc fonctionnelle : `blindtest/docs/library-playlists.md`.

## Déploiement

Sur le nœud Proxmox, en root :

```
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-clashbuzz-studio.sh)
```

Socle standard (Ubuntu 24.04, unprivileged, DHCP) puis couche applicative
([`setup-app.sh`](setup-app.sh), relançable seule) : Node 22, clone du repo
(PAT GitHub demandé), `pnpm install + build` de `apps/studio`, service
systemd `clashbuzz-studio` (port **8090**, secrets dans
`/home/thibault/studio-data/settings.json`, chmod 600).

## Post-install (manuel)

1. **Vhost Caddy interne** (CT 100) — [`../internal/Caddyfile`](../internal/Caddyfile) :
   ```
   clashbuzz-studio.ts.tlagrange.pro {
   	reverse_proxy <IP_DU_CT>:8090
   }
   ```
   et l'entrée DNS dans [`../internal/extra-records.yaml`](../internal/extra-records.yaml) :
   ```
   - { name: "clashbuzz-studio.ts.tlagrange.pro", type: A, value: "100.64.0.2" }
   ```
   → accessible UNIQUEMENT depuis le tailnet (pas d'auth applicative).
2. **Bail DHCP statique** pour l'IP du CT dans la box.
3. Dans l'UI (onglet 🔑 Comptes) : URL du studio, app Spotify du compte dédié
   (+ Connecter), cookie ARL Deezer (+ Tester), client OAuth Google web
   (+ Connecter, écran de consentement en Production), URL + service role
   Supabase.

## Mise à jour

```
pct exec <VMID> -- su - thibault -c "cd ~/blindtest && git pull --ff-only \
  && corepack pnpm install --filter @blindtest/studio --frozen-lockfile=false \
  && corepack pnpm --filter @blindtest/studio build"
pct exec <VMID> -- systemctl restart clashbuzz-studio
```

## Exploitation

```
pct exec <VMID> -- systemctl status clashbuzz-studio
pct exec <VMID> -- journalctl -u clashbuzz-studio -n 50
```

Sauvegarde utile : `/home/thibault/studio-data/settings.json` (tokens OAuth,
ARL — régénérables mais pénibles).
