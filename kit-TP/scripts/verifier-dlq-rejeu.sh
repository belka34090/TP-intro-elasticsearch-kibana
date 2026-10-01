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

# Crée un seul document invalide à partir de la dernière offre :
# nouvel id métier + champ 'prime' interdit par le mapping strict.
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

docker compose restart logstash >/dev/null

echo "Attente du traitement du document invalide..."
sleep 8

echo
echo "OFF-99999 doit être absent de l'index :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/offres/_doc/OFF-99999?pretty" || true

echo
echo "Le compteur offres doit rester à 5000 :"
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/offres/_count?pretty"

echo
echo "Trace d'erreur d'indexation / DLQ :"
docker compose logs --no-color logstash   | grep -Ei "could not index|dead.?letter|strict_dynamic_mapping_exception|document_parsing_exception|prime"   | tail -30 || true

echo
echo "Contenu du répertoire DLQ :"
docker compose exec -T logstash   sh -lc 'find /usr/share/logstash/data/dead_letter_queue -maxdepth 2 -type f -printf "%p %s octets\n" 2>/dev/null || true'

rm -f data/offres_test.ndjson

echo
echo "== B. Exercice 3.5 — rejeu du fichier web =="

avant=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"   "http://localhost:9200/logs-web-default/_count"   | python -c 'import json,sys; print(json.load(sys.stdin)["count"])')

echo "Avant redémarrage : $avant"

docker compose restart logstash >/dev/null

echo "Attente du rejeu..."
for _ in $(seq 1 60); do
  apres=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"     "http://localhost:9200/logs-web-default/_count" 2>/dev/null     | python -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)
  if [[ "$apres" -ge $((avant + 20700)) ]]; then
    break
  fi
  sleep 2
done

echo "Après redémarrage : $apres"
echo "Attendu si sincedb=/dev/null et aucun _id stable : $((avant + 20700))"

echo
echo "== C. Retour à un état propre =="
docker compose stop logstash >/dev/null
curl -sS -u "elastic:${ELASTIC_PASSWORD}"   -X DELETE "http://localhost:9200/_data_stream/logs-web-default" >/dev/null || true
docker compose up -d logstash >/dev/null

for _ in $(seq 1 60); do
  propre=$(curl -sS -u "elastic:${ELASTIC_PASSWORD}"     "http://localhost:9200/logs-web-default/_count" 2>/dev/null     | python -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo 0)
  if [[ "$propre" == "20700" ]]; then
    break
  fi
  sleep 2
done

echo "État final logs-web-default : $propre"
echo "État final offres : $(curl -sS -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9200/offres/_count" | python -c 'import json,sys; print(json.load(sys.stdin)["count"])')"

echo
echo "VERIFICATIONS COMPLEMENTAIRES TERMINEES"
