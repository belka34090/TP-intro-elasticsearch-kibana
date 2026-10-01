#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "ERREUR: .env absent."
  exit 1
fi

set -a
source .env
set +a

KIBANA_URL="http://localhost:5601"
AUTH="elastic:${ELASTIC_PASSWORD}"

echo "== Vérification Kibana =="
curl -sS -u "$AUTH" "$KIBANA_URL/api/status"   | python -c 'import json,sys; d=json.load(sys.stdin); print("Kibana :", d.get("status",{}).get("overall",{}).get("level","inconnu"))'

echo
echo "== Data view : Logs web =="
curl -sS -u "$AUTH"   -X POST "$KIBANA_URL/api/data_views/data_view"   -H "kbn-xsrf: true"   -H "Content-Type: application/json"   -d '{
    "override": true,
    "data_view": {
      "id": "logs-web",
      "name": "Logs web",
      "title": "logs-web-*",
      "timeFieldName": "@timestamp"
    }
  }'   | python -c 'import json,sys; d=json.load(sys.stdin); v=d.get("data_view",{}); print(v.get("name"), "->", v.get("title"), "| temps:", v.get("timeFieldName"))'

echo
echo "== Data view : offres =="
curl -sS -u "$AUTH"   -X POST "$KIBANA_URL/api/data_views/data_view"   -H "kbn-xsrf: true"   -H "Content-Type: application/json"   -d '{
    "override": true,
    "data_view": {
      "id": "offres",
      "name": "offres",
      "title": "offres"
    }
  }'   | python -c 'import json,sys; d=json.load(sys.stdin); v=d.get("data_view",{}); print(v.get("name"), "->", v.get("title"))'

echo
echo "== Data views disponibles =="
curl -sS -u "$AUTH" "$KIBANA_URL/api/data_views"   | python -c 'import json,sys; d=json.load(sys.stdin); [print("-", x.get("name"), "=>", x.get("title"), "(id:", x.get("id"), ")") for x in d.get("data_view",[])]'

echo
echo "PREPARATION KIBANA TERMINEE"
