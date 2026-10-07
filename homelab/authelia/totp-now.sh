#!/usr/bin/env bash
#
# totp-now.sh — affiche le code TOTP que le serveur Authelia attend MAINTENANT
# pour un utilisateur, calculé depuis le secret stocké côté Authelia. Sert à
# vérifier, sans passer par le portail, que l'appli TOTP (Bitwarden…) est bien
# alignée : mêmes codes = même secret et horloges justes. Le secret lui-même
# n'est jamais affiché.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash totp-now.sh [VMID] [utilisateur]      # défauts : 102 thibault
#   CODE=123456 bash totp-now.sh               # cherche à quel décalage d'horloge
#                                              # ce code (lu dans l'appli) correspond

set -euo pipefail

VMID="${1:-102}"
USER_NAME="${2:-thibault}"

pct exec "$VMID" -- docker exec authelia authelia storage user totp export uri \
    --config /config/configuration.yml \
| USER_NAME="$USER_NAME" CODE="${CODE:-}" python3 -c '
import base64, hashlib, hmac, os, re, struct, sys, time
from urllib.parse import urlparse, parse_qs, unquote

user = os.environ["USER_NAME"]
uris = re.findall(r"otpauth://totp/\S+", sys.stdin.read())
uris = [u for u in uris if unquote(urlparse(u).path).rstrip("/").endswith(":" + user)
        or unquote(urlparse(u).path).strip("/") == user]
if not uris:
    sys.exit("Aucune configuration TOTP trouvée pour " + user)
q = parse_qs(urlparse(uris[0]).query)
secret = q["secret"][0].upper()
digits = int(q.get("digits", ["6"])[0])
period = int(q.get("period", ["30"])[0])
algo = q.get("algorithm", ["SHA1"])[0].lower()
key = base64.b32decode(secret + "=" * (-len(secret) % 8))

def code(t):
    h = hmac.new(key, struct.pack(">Q", int(t) // period), getattr(hashlib, algo)).digest()
    o = h[-1] & 15
    return str((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits).zfill(digits)

now = time.time()
print("Paramètres : %s, %d chiffres, période %ds, secret de %d caractères" % (algo.upper(), digits, period, len(secret)))
print("Heure UTC  : " + time.strftime("%H:%M:%S", time.gmtime(now)))
print("Code précédent : " + code(now - period))
print("Code ACTUEL    : %s   (encore %ds)" % (code(now), period - int(now) % period))
print("Code suivant   : " + code(now + period))

seen = os.environ.get("CODE", "").replace(" ", "")
if seen:
    steps = 86400 // period
    hits = [k for k in range(-steps, steps + 1) if code(now + k * period) == seen.zfill(digits)]
    if not hits:
        print("\nLe code %s ne correspond à AUCUN instant sur +/- 24 h : le secret de l appli est différent de celui du serveur." % seen)
    else:
        k = min(hits, key=abs)
        if k == 0:
            print("\nLe code %s est le code actuel : appli et serveur alignés." % seen)
        else:
            print("\nLe code %s correspond à un décalage de %+d s (%+.1f min) : même secret, horloge de l appareil %s." % (seen, k * period, k * period / 60, "en avance" if k > 0 else "en retard"))
'
