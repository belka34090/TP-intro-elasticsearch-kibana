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

for var in ELASTIC_PASSWORD LOGSTASH_INTERNAL_PASSWORD STACK_VERSION; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERREUR: variable $var absente de .env"
    exit 1
  fi
done

echo "== 1. Stack Elasticsearch/Kibana =="
docker compose up -d
docker compose ps

echo
echo "== 2. Données offres =="
python data/generate_offres.py
python ingest.py --reset

echo
echo "== 3. Syntaxe des pipelines =="
docker compose run --rm --no-deps logstash --path.data /tmp/test-offres   --config.test_and_exit -f /usr/share/logstash/pipeline/offres.conf

docker compose run --rm --no-deps logstash --path.data /tmp/test-web   --config.test_and_exit -f /usr/share/logstash/pipeline/web.conf

echo
echo "== 4. Génération des logs web =="
docker compose stop logstash >/dev/null 2>&1 || true
rm -f data/offres_test.ndjson
python data/generate_access_logs.py
wc -l data/access.log

echo
echo "== 5. Remise à zéro du data stream web =="
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   -X DELETE "http://localhost:9200/_data_stream/logs-web-default" >/dev/null || true

echo
echo "== 6. Démarrage Logstash =="
docker compose up -d logstash

echo "Attente de l'ingestion..."
for _ in $(seq 1 60); do
  count=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"     "http://localhost:9200/logs-web-default/_count" 2>/dev/null     | python -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)
  if [[ "$count" == "20700" ]]; then
    break
  fi
  sleep 2
done

echo
echo "== 7. Contrôles Elasticsearch =="
echo -n "offres : "
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/offres/_count?pretty"

echo -n "logs-web-default : "
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/logs-web-default/_count?pretty"

echo "Échecs grok :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   -H "Content-Type: application/json"   "http://localhost:9200/logs-web-default/_count?pretty"   -d '{"query":{"term":{"tags":"_grokparsefailure"}}}'

echo
echo "Premier événement :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   -H "Content-Type: application/json"   "http://localhost:9200/logs-web-default/_search?pretty"   -d '{"size":1,"sort":[{"@timestamp":"asc"}]}'

echo
echo "Data stream :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/_data_stream/logs-web-default?pretty"

echo
echo "Mode d'index :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/logs-web-default/_settings?filter_path=*.settings.index.mode&pretty"

echo
echo "== 8. Supervision Logstash =="
curl -sS "http://localhost:9600/_node/pipelines?pretty"
curl -sS "http://localhost:9600/_node/stats/pipelines/offres?pretty"

echo
echo "VALIDATION TERMINEE"
echo "Attendus principaux : offres=5000, logs-web-default=20700, grok failures=0."
