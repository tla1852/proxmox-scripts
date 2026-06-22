# homelab/edge — Edge Caddy + CrowdSec

Conf de l'edge public (LXC 144 du homelab, cf. [tla1852/homelab-secu](https://github.com/tla1852/homelab-secu), phase 4).

- `Caddyfile` — reverse proxy des 9 vhosts publics + handler **CrowdSec** par site (`import prot`) + log JSON vers `/var/log/caddy/access.log`.
- `docker-compose.yml` — services `caddy` (image custom `caddy-crowdsec:2.11`) + `crowdsec` (engine, collections caddy/http-cve/base-http-scenarios), partage du volume `logs/`.
- `acquis.yaml` — acquisition CrowdSec sur les logs Caddy.

Image custom (module bouncer) à builder une fois sur l'edge :

```bash
cat > /opt/caddy/Dockerfile <<'EOF'
FROM caddy:2.11-builder AS builder
ENV GOTOOLCHAIN=auto
RUN xcaddy build --with github.com/hslatman/caddy-crowdsec-bouncer
FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF
docker build -t caddy-crowdsec:2.11 /opt/caddy
```

## Déploiement (sur l'edge, dans /opt/caddy)

```bash
cd /opt/caddy
mkdir -p logs crowdsec/data
touch crowdsec.env
curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/edge/Caddyfile          -o Caddyfile
curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/edge/docker-compose.yml  -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/edge/acquis.yaml         -o crowdsec/acquis.yaml

# 1. CrowdSec d'abord (installe les collections, ouvre la LAPI)
docker compose up -d crowdsec
sleep 10
docker exec crowdsec cscli collections list

# 2. Clé bouncer pour Caddy
docker exec crowdsec cscli bouncers add caddy-edge
# -> copier la clé, puis :
echo "CROWDSEC_BOUNCER_KEY=<LA_CLE>" > crowdsec.env

# 3. Caddy (nouvelle image + bouncer)
docker compose up -d
docker compose logs --tail 20 caddy

# Vérifs
docker exec crowdsec cscli metrics
docker exec crowdsec cscli decisions list
```

`crowdsec.env` (clé bouncer) n'est pas versionné — local à l'edge.
