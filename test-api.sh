#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-api.sh — comprueba que el servidor responde y que el modelo razona.
#
#   bash test-api.sh
#   BASE_URL=http://localhost:9000 API_KEY=sk-local bash test-api.sh
# ---------------------------------------------------------------------------
set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-bonsai-2-27b}"

AUTH=()
[[ -n "$API_KEY" ]] && AUTH=(-H "Authorization: Bearer $API_KEY")

echo "== GET $BASE_URL/v1/models"
curl -fsS "${AUTH[@]}" "$BASE_URL/v1/models" | python3 -m json.tool

echo
echo "== POST $BASE_URL/v1/chat/completions"
# max_tokens alto: el modelo razona antes de responder y el razonamiento consume
# presupuesto de salida (ver KNOWN_ISSUES del modelo). reasoning_effort: 'high'
# devuelve HTTP 500; usa 'medium' o 'xhigh'.
curl -fsS "${AUTH[@]}" -H 'Content-Type: application/json' \
  "$BASE_URL/v1/chat/completions" -d @- <<JSON | python3 -m json.tool
{
  "model": "$MODEL",
  "messages": [
    {"role": "user", "content": "En una frase: ¿qué es un peso ternario {-1, 0, +1}?"}
  ],
  "max_tokens": 16384,
  "temperature": 0.7,
  "reasoning_effort": "medium"
}
JSON

echo
echo "OK: el endpoint responde en formato OpenAI."
