#!/usr/bin/env bash
# Poller user (cron) : export facturation GCP (BigQuery) -> L5 /webhooks/gcp-billing.
# Prérequis : gcloud auth user sur claude-dev + export standard activé dans la
# console Billing vers clashbuzz-prod:billing_export. Latence export ~1 jour.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./env
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

TABLE="${GCP_BILLING_TABLE:-clashbuzz-prod.billing_export.gcp_billing_export_v1_01F35B_137FD5_A5FC5C}"
DAYS="${DAYS:-35}"

QUERY="SELECT FORMAT_DATE('%Y-%m-%d', DATE(usage_start_time, 'Europe/Paris')) AS jour,
  project.id AS projet, service.description AS service, currency AS devise,
  ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 4) AS cost
FROM \`${TABLE}\`
WHERE usage_start_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE('Europe/Paris'), INTERVAL ${DAYS} DAY))
GROUP BY 1, 2, 3, 4"

# Table absente tant que l'export n'est pas activé : sortir sans bruit.
ROWS=$(bq query --project_id=clashbuzz-prod --use_legacy_sql=false --format=json --max_rows=10000 "$QUERY" 2>/dev/null) || { echo "$(date -Is) table export absente ou requête KO, skip"; exit 0; }

ROWS_JSON="$ROWS" L5_URL="$L5_URL" L5_WEBHOOK_SECRET="${L5_WEBHOOK_SECRET:-}" python3 - <<'PYEOF'
import json, os, urllib.request
rows = json.loads(os.environ["ROWS_JSON"] or "[]")
days = [{"jour": r["jour"], "projet": r.get("projet") or "?", "service": r.get("service") or "?",
         "cost": float(r["cost"]), "devise": r.get("devise") or "EUR"} for r in rows]
req = urllib.request.Request(
    os.environ["L5_URL"].rstrip("/") + "/webhooks/gcp-billing",
    data=json.dumps({"days": days}).encode(),
    headers={"Content-Type": "application/json", "X-L5-Secret": os.environ["L5_WEBHOOK_SECRET"]},
    method="POST")
with urllib.request.urlopen(req, timeout=30) as resp:
    print(f"{len(days)} lignes -> L5 : {resp.status} {resp.read().decode()[:200]}")
PYEOF
