# Supervision — Prometheus + Grafana (homelab + GCP)

Moteur de supervision du parc, conforme au design du module **Supervision de L5**
(L5 = surface unique ; ici = collecte, stockage timeseries, alerting).

```
┌───────────────────────── LXC supervision (docker compose) ─────────────────────────┐
│  prometheus:9090  ←─ pve-exporter:9221 ── API Proxmox (token monitoring@pve, RO)   │
│        │          ←─ blackbox:9115 ────── probes HTTP LAN + apps GCP publiques     │
│        │          ←─ 192.168.1.101:9100 ─ node_exporter natif sur l'hôte PVE       │
│        │          ←─ HTTPS + basic auth ─ stackdriver-exporter (Cloud Run, GCP)    │
│  grafana:3000 ── alertes ──→ POST http://192.168.1.43:3000/webhooks/grafana (L5)   │
└────────────────────────────────────────────────────────────────────────────────────┘
```

## Déploiement

Sur le nœud Proxmox, en root :

```
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-supervision.sh)
```

Le script :
- crée le LXC (socle standard : Ubuntu 24.04, DHCP, unprivileged, Docker) ;
- installe `prometheus-node-exporter` **sur l'hôte PVE** (port 9100) ;
- crée l'utilisateur API `monitoring@pve` + token `supervision` (rôle **PVEAuditor**,
  lecture seule) et écrit `secrets/pve.yml` ;
- demande : mot de passe admin Grafana, secret webhook L5, mot de passe de scrape GCP ;
- clone ce repo dans le CT (`/opt/proxmox-scripts`) et lance `docker compose up -d`
  depuis `homelab/supervision/`.

La couche applicative vit dans [`setup-app.sh`](setup-app.sh) — **relançable seule**
sur un CT existant si le run a échoué en cours de route (détecte un node_exporter
déjà présent sur :9100 au lieu de planter) :

```
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/supervision/setup-app.sh) <VMID>
```

Secrets demandés :
- **Secret webhook L5** : `pct exec <CTID_L5> -- grep GRAFANA_WEBHOOK_SECRET /opt/l5/.env`
- **Mot de passe scrape GCP** : généré lors du déploiement du stackdriver-exporter
  (voir `~/supervision-secrets.txt` sur claude-dev).

## Côté GCP (déjà en place)

L'org policy `iam.disableServiceAccountKeyCreation` interdit les clés SA. Solution
sans clé : `stackdriver-exporter` tourne **dans Cloud Run** (projet `clashbuzz-prod`,
région `europe-west1`) avec le service account `supervision-metrics@clashbuzz-prod`
attaché (rôle `roles/monitoring.viewer`). Auth entrante = basic auth
(exporter-toolkit, secret `stackdriver-exporter-webconfig` dans Secret Manager,
user `prometheus`). Prometheus le scrape en HTTPS toutes les 60 s.

- URL : `https://stackdriver-exporter-824477654962.europe-west1.run.app`
- Métriques : `stackdriver_cloud_run_revision_run_googleapis_com_*`
- Ajouter un projet GCP : donner `monitoring.viewer` au SA sur le nouveau projet
  puis ajouter `--google.project-id=<id>` aux args du service Cloud Run.

## Post-install (manuel)

1. **Vhost Grafana** (Caddy interne CT 100) : ajouter à
   [`internal/Caddyfile`](../internal/Caddyfile) et recharger :
   ```
   grafana.ts.tlagrange.pro {
   	reverse_proxy <IP_DU_CT>:3000
   }
   ```
   et l'entrée DNS dans [`internal/extra-records.yaml`](../internal/extra-records.yaml) :
   ```
   - { name: "grafana.ts.tlagrange.pro", type: A, value: "100.64.0.2" }
   ```
2. **L5** : dans `/opt/l5/.env` du CT L5, pointer
   `PROMETHEUS_URL=http://<IP_DU_CT>:9090` et
   `GRAFANA_URL=https://grafana.ts.tlagrange.pro`, puis `docker compose up -d`.
3. **Dashboards** : importer dans Grafana (Dashboards → Import) :
   - `1860` — Node Exporter Full (hôte PVE)
   - `10347` — Proxmox via pve-exporter
   - `7587` — Blackbox Exporter (probes HTTP)
4. **Réserver l'IP du CT** dans la box (bail DHCP statique).

## Alerting

Contact point + policy + 5 règles de base provisionnés (dossier *Supervision*) :
cible down, probe HTTP down, guest Proxmox down, disque hôte < 10 %, 5xx Cloud Run.
Tout part vers `POST /webhooks/grafana` de L5 (Bearer `SUPERVISION_WEBHOOK_SECRET`)
→ table `alerte` → page Supervision + cadre alerting de la home. Les règles
supplémentaires se créent dans l'UI Grafana, dossier *Supervision*.

## Exploitation

```
pct exec <CTID> -- bash -c 'cd /opt/proxmox-scripts/homelab/supervision && docker compose logs -f'
pct exec <CTID> -- bash -c 'cd /opt/proxmox-scripts && git pull && cd homelab/supervision && docker compose up -d'
```

Cibles à faire évoluer : éditer `prometheus/prometheus.yml` (probes blackbox) puis
`docker compose restart prometheus`.
