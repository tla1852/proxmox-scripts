# homelab/edge — Edge Caddy + CrowdSec

Conf de l'edge public (LXC 144 du homelab, cf. [tla1852/homelab-secu](https://github.com/tla1852/homelab-secu), phase 4).

- `Caddyfile` — reverse proxy des 10 vhosts publics + handler **CrowdSec** par site (`import prot`) + log JSON vers `/var/log/caddy/access.log`.
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

## Accès bureau (services privés hors tailnet)

Le poste du bureau ne peut pas rejoindre le tailnet. Les 19 vhosts
`*.ts.tlagrange.pro` sont donc aussi servis par l'edge, **uniquement** pour l'IP
publique du bureau (`46.255.204.70`, partagée) et derrière **Authelia**
(mot de passe + TOTP, `create-lxc-authelia.sh`).

```
bureau ─▶ edge (IP bureau ? sinon abort) ─▶ Authelia (session 2FA ? sinon portail)
                                          └▶ Caddy interne .72 ─▶ service
```

- `Caddyfile` — bloc « ACCÈS BUREAU » : `auth.ts.tlagrange.pro` (portail) + les
  19 vhosts privés (`forward_auth` puis relais vers `https://192.168.1.72`).
- `144.fw` — 2 règles egress : edge → Authelia `:9091`, edge → Caddy interne `:443`.
- `dns-bureau.sh` — CNAME publics Gandi `<svc>.ts` → `survivalmode.familyds.org`.
  Les clients tailnet continuent de résoudre `100.64.0.2` via MagicDNS.

> ⚠️ Compromis assumé : ces deux règles donnent à l'edge (DMZ) un chemin vers
> tous les services privés, et le bureau fait de l'inspection TLS (le proxy du
> bureau voit le trafic en clair). Web uniquement : les clients non-navigateur
> (Bitwarden desktop, Drive, Hammer) ne passent pas le portail.

### Mise en service

1. **Authelia** (hôte Proxmox) : lancer `create-lxc-authelia.sh`, noter l'IP,
   réserver le bail DHCP.
2. **Repo** : remplacer `AUTHELIA_IP` par cette IP dans `Caddyfile` et `144.fw`.
3. **DNS** : `GANDI_API_TOKEN=… bash dns-bureau.sh`, puis vérifier
   `dig +short @1.1.1.1 auth.ts.tlagrange.pro`.
4. **Firewall** (hôte Proxmox) : déposer `144.fw` dans `/etc/pve/firewall/144.fw`
   (appliqué à chaud), vérifier `pve-firewall status`.
5. **Caddy** (edge, `/opt/caddy`) : récupérer le `Caddyfile` puis
   `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile` ;
   suivre l'émission des 20 certs dans `docker compose logs -f caddy`.
6. **Tests** :
   - en 4G : `curl -I https://n8n.ts.tlagrange.pro` → connexion coupée ;
   - au bureau : redirection vers `auth.ts.tlagrange.pro`, login, enrôlement
     TOTP (code de vérification : `notification.txt` du CT Authelia), accès OK ;
   - sur le tailnet : comportement inchangé, pas de portail.

### Retrait

`bash dns-bureau.sh --delete`, retirer le bloc « ACCÈS BUREAU » du `Caddyfile`
et les 2 règles de `144.fw`, recharger. Le CT Authelia peut alors être arrêté.
