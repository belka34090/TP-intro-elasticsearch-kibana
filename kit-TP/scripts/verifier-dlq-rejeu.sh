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

echo "== A. Exercice 2.2 — DLQ =="

# On isole ce test du pipeline web, sinon access.log serait relu à chaque redémarrage.
docker compose stop logstash >/dev/null
mv data/access.log data/access.log.tmp-dlq

python - <<'PY'
import json
from pathlib import Path

src = Path("data/offres.ndjson")
dst = Path("data/offres_test.ndjson")

doc = json.loads(src.read_text(encoding="utf-8").splitlines()[-1])
doc["id"] = "OFF-99999"
doc["prime"] = 3000
dst.write_text(json.dumps(doc, ensure_ascii=False) + "\n", encoding="utf-8")
print("Document de test créé :", dst)
PY

docker compose up -d logstash >/dev/null

echo "Attente du traitement du document invalide..."
sleep 25

echo
echo "OFF-99999 doit être absent de l'index :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/offres/_doc/OFF-99999?pretty" || true

echo
echo "Le compteur offres doit rester à 5000 :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/offres/_count?pretty"

echo
echo "Trace d'erreur d'indexation / DLQ :"
docker compose logs --no-color --since=3m logstash   | grep -Ei "OFF-99999|prime|could not index|dynamic.*strict|document_parsing_exception|dead.?letter"   | tail -40 || true

echo
echo "Contenu du répertoire DLQ :"
docker compose exec -T logstash   sh -lc 'find /usr/share/logstash/data/dead_letter_queue -maxdepth 2 -type f -printf "%p %s octets\n" 2>/dev/null || true'

rm -f data/offres_test.ndjson
docker compose stop logstash >/dev/null
mv data/access.log.tmp-dlq data/access.log

echo
echo "== B. Exercice 3.5 — rejeu du fichier web =="

# Repart d'un data stream propre.
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   -X DELETE "http://localhost:9200/_data_stream/logs-web-default" >/dev/null || true

docker compose up -d logstash >/dev/null

echo "Attente de l'ingestion initiale à 20700..."
for _ in $(seq 1 90); do
  avant=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"     "http://localhost:9200/logs-web-default/_count" 2>/dev/null     | python -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)
  if [[ "$avant" == "20700" ]]; then
    break
  fi
  sleep 2
done

echo "Avant redémarrage : $avant"

docker compose restart logstash >/dev/null

echo "Attente d'un seul rejeu complet..."
for _ in $(seq 1 90); do
  apres=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"     "http://localhost:9200/logs-web-default/_count" 2>/dev/null     | python -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)
  if [[ "$apres" == "41400" ]]; then
    break
  fi
  sleep 2
done

echo "Après redémarrage : $apres"
echo "Attendu : 41400"

echo
echo "== C. Retour à un état propre =="

docker compose stop logstash >/dev/null
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   -X DELETE "http://localhost:9200/_data_stream/logs-web-default" >/dev/null || true

docker compose up -d logstash >/dev/null

for _ in $(seq 1 90); do
  propre=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"     "http://localhost:9200/logs-web-default/_count" 2>/dev/null     | python -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)
  if [[ "$propre" == "20700" ]]; then
    break
  fi
  sleep 2
done

echo "État final logs-web-default : $propre"
echo "État final offres : $(curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/offres/_count"   | python -c 'import json,sys; print(json.load(sys.stdin)["count"])')"

echo
echo "VERIFICATIONS COMPLEMENTAIRES TERMINEES"
