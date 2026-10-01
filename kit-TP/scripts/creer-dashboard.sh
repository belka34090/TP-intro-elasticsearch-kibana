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
DASHBOARD_ID="site-recrutement-trafic"

payload=$(cat <<'JSON'
{
  "title": "Site de recrutement — trafic",
  "description": "Tableau de bord du TP2 Logstash : trafic web, erreurs serveur, offres consultées et navigateurs.",
  "time_range": {
    "from": "2026-09-22T22:00:00.000Z",
    "to": "2026-09-29T22:00:00.000Z"
  },
  "panels": [
    {
      "grid": { "x": 0, "y": 0, "w": 12, "h": 5 },
      "type": "vis",
      "config": {
        "type": "metric",
        "title": "Requêtes",
        "data_source": {
          "type": "data_view_spec",
          "index_pattern": "logs-web-*",
          "time_field": "@timestamp"
        },
        "metrics": [
          {
            "type": "primary",
            "operation": "count",
            "label": "Requêtes"
          }
        ]
      }
    },
    {
      "grid": { "x": 12, "y": 0, "w": 12, "h": 5 },
      "type": "vis",
      "config": {
        "type": "metric",
        "title": "Taux d'erreurs serveur",
        "data_source": {
          "type": "data_view_spec",
          "index_pattern": "logs-web-*",
          "time_field": "@timestamp"
        },
        "metrics": [
          {
            "type": "primary",
            "operation": "formula",
            "formula": "count(kql='http.response.status_code >= 500') / count()",
            "label": "Taux 5xx",
            "format": {
              "type": "percent",
              "decimals": 2,
              "compact": false
            }
          }
        ]
      }
    },
    {
      "grid": { "x": 0, "y": 5, "w": 48, "h": 12 },
      "type": "vis",
      "config": {
        "type": "xy",
        "title": "Trafic dans le temps par code HTTP",
        "layers": [
          {
            "type": "bar_stacked",
            "data_source": {
              "type": "data_view_spec",
              "index_pattern": "logs-web-*",
              "time_field": "@timestamp"
            },
            "x": {
              "operation": "date_histogram",
              "field": "@timestamp"
            },
            "y": [
              {
                "operation": "count",
                "label": "Requêtes"
              }
            ],
            "breakdown_by": {
              "operation": "terms",
              "fields": ["http.response.status_code"],
              "limit": 10
            }
          }
        ]
      }
    },
    {
      "grid": { "x": 0, "y": 17, "w": 24, "h": 12 },
      "type": "vis",
      "config": {
        "type": "data_table",
        "title": "Offres les plus consultées",
        "data_source": {
          "type": "esql",
          "query": "FROM logs-web-default | WHERE http.request.method == \"GET\" AND http.response.status_code == 200 AND labels.offre_id IS NOT NULL | STATS consultations = COUNT(*) BY labels.offre_id | SORT consultations DESC, labels.offre_id ASC | LIMIT 10"
        },
        "rows": [
          { "column": "labels.offre_id" }
        ],
        "metrics": [
          { "column": "consultations" }
        ]
      }
    },
    {
      "grid": { "x": 24, "y": 17, "w": 24, "h": 12 },
      "type": "vis",
      "config": {
        "type": "pie",
        "title": "Navigateurs",
        "data_source": {
          "type": "data_view_spec",
          "index_pattern": "logs-web-*",
          "time_field": "@timestamp"
        },
        "metrics": [
          { "operation": "count" }
        ],
        "group_by": [
          {
            "operation": "terms",
            "fields": ["user_agent.name"],
            "limit": 5
          }
        ],
        "styling": {
          "donut_hole": "m",
          "labels": { "visible": true, "position": "outside" },
          "values": { "visible": true, "mode": "percentage" }
        }
      }
    }
  ]
}
JSON
)

echo "== Création/mise à jour du dashboard =="
response=$(curl -sS -w "\n%{http_code}" -u "$AUTH"   -X PUT "$KIBANA_URL/api/dashboards/$DASHBOARD_ID"   -H "kbn-xsrf: true"   -H "Content-Type: application/json"   -d "$payload")

body=$(printf '%s\n' "$response" | sed '$d')
status=$(printf '%s\n' "$response" | tail -n 1)

echo "HTTP $status"
printf '%s\n' "$body" | python -m json.tool 2>/dev/null || printf '%s\n' "$body"

if [[ "$status" != "200" && "$status" != "201" ]]; then
  echo "ERREUR: Kibana a refusé le dashboard."
  exit 1
fi

echo
echo "== Vérification =="
curl -sS -u "$AUTH" "$KIBANA_URL/api/dashboards/$DASHBOARD_ID"   | python -m json.tool

echo
echo "Dashboard : $KIBANA_URL/app/dashboards#/view/$DASHBOARD_ID"
echo "Les 5 panneaux pris en charge par l'API Kibana 9.5 sont créés."
echo "Il reste à ajouter le panneau Maps 'Offres par localisation' dans l'interface Kibana."
