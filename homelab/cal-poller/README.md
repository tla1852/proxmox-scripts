# cal-poller — miroir calendrier Proton → L5

Synchronise l'agenda Proton vers [L5](https://github.com/tla1852/l5)
(`POST /webhooks/calendrier`, upsert par UID). Tourne dans le LXC `proton-caldav`
en timer systemd (3 min).

## Installation (dans le LXC, root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/cal-poller/install.sh)
```

## Deux modes (cf. `poller.py`)

- **ICS (recommandé)** — `CAL_ICS_URLS` : lien `.ics` partagé par Proton
  (Paramètres → Mes calendriers → Partager → lien). Proton sert son propre
  export ; simple et robuste.
- **CalDAV (fallback)** — via ferroxide (`127.0.0.1:8081`).
  ⚠️ **Inutilisable si un événement a un auteur sans email** : ferroxide renvoie
  un `500` (`[33101] could not get public keys for author`) même pour *lister* la
  collection, ce qui bloque tout. Dans ce cas → utiliser le mode ICS.

Le mode ICS prime dès que `CAL_ICS_URLS` est défini.

## Exploitation

```bash
systemctl start cal-poller.service                 # sync immédiate
journalctl -u cal-poller.service -n 20 --no-pager  # "mode=ics N événements -> 200"
systemctl list-timers cal-poller.timer
nano /etc/cal-poller.env                            # config (chmod 600)
```

Fenêtre synchronisée : `WINDOW_PAST_DAYS` (7) → `WINDOW_FUTURE_DAYS` (90).
Récurrences non expansées (event maître affiché une fois). Suppressions Proton
non répercutées (upsert seul).
