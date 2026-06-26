# homelab/internal — Caddy interne (tailnet) + MagicDNS

État versionné du plan privé (cf. [tla1852/homelab-secu](https://github.com/tla1852/homelab-secu)). Reachable **uniquement via le tailnet** (Headscale).

- `Caddyfile` — vhosts `*.ts.tlagrange.pro` → IP LAN privées, sur le **Caddy interne** (LXC 100, tailnet `100.64.0.2`, image `caddy-gandi:2.10`). Certs **Let's Encrypt DNS-01 Gandi** (token en env `GANDI_API_TOKEN`).
- `extra-records.yaml` — bloc `dns.extra_records` de Headscale (LXC 145) : chaque nom → `100.64.0.2`.

> ⚠️ Garder `Caddyfile` et `extra-records.yaml` **synchro** : tout vhost ajouté ici doit avoir son `extra_record` (sinon le nom ne résout pas sur le tailnet). Ajout d'un service : voir la doc L5 « Homelab / Caddy interne / Ajouter un service privé ».

## Ré-application

### Caddy interne (LXC 100)
```bash
# (re)build l'image avec le module Gandi si besoin
cat > /opt/caddy-internal/Dockerfile <<'EOF'
FROM caddy:2.10-builder AS builder
ENV GOTOOLCHAIN=auto
RUN xcaddy build --with github.com/caddy-dns/gandi
FROM caddy:2.10
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF
docker build -t caddy-gandi:2.10 /opt/caddy-internal

# déposer ce Caddyfile, puis lancer (token Gandi en env)
docker rm -f caddy-internal 2>/dev/null
docker run -d --name caddy-internal --restart unless-stopped --network host \
  -e GANDI_API_TOKEN='<token>' \
  -v /opt/caddy-internal/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /opt/caddy-internal/data:/data -v /opt/caddy-internal/config:/config \
  caddy-gandi:2.10
```

### MagicDNS (LXC 145)
Reporter le bloc `extra-records.yaml` dans la section `dns:` de
`/opt/headscale/config/config.yaml` (remplacer `extra_records: []` / le bloc
existant), puis `docker restart headscale`.
