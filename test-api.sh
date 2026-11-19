#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-api.sh — comprueba que llama-server responde y que el modelo contesta.
#
#   bash test-api.sh
#   MODEL=glm-4.7-flash bash test-api.sh
#   BASE_URL=http://192.168.1.50:8000 API_KEY=sk-local bash test-api.sh
#
# Bonsai hace una prueba RÁPIDA (sin razonamiento). Para ver el razonamiento:
#   MAX_TOKENS=16384 REASONING_EFFORT=medium bash test-api.sh
# GLM no envía reasoning_effort (su plantilla no lo usa) y usa 8192 tokens.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
API_KEY="${API_KEY:-}"
MODEL="${MODEL:-bonsai-2-27b}"

if [[ "$MODEL" == *glm* ]]; then
  MAX_TOKENS="${MAX_TOKENS:-8192}"
  REASONING_EFFORT="${REASONING_EFFORT:-}"
else
  MAX_TOKENS="${MAX_TOKENS:-1024}"
  REASONING_EFFORT="${REASONING_EFFORT:-none}"
fi

EXTRA_JSON=""
if [[ -n "$REASONING_EFFORT" ]]; then
  EXTRA_JSON=$',\n  "reasoning_effort": "'"$REASONING_EFFORT"'"'
fi

[[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] || { echo "MAX_TOKENS inválido: $MAX_TOKENS" >&2; exit 1; }

AUTH=()
[[ -n "$API_KEY" ]] && AUTH=(-H "Authorization: Bearer $API_KEY")

# Formatea JSON si hay python3; si no, lo muestra tal cual.
pretty() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool
  else
    cat
  fi
}

echo "== GET $BASE_URL/health"
curl -fsS "$BASE_URL/health" | pretty

echo
echo "== GET $BASE_URL/v1/models"
curl -fsS "${AUTH[@]}" "$BASE_URL/v1/models" | pretty

echo
echo "== POST $BASE_URL/v1/chat/completions"
# Prueba rápida: pocos tokens y sin razonamiento. Para uso real, max_tokens
# alto (16384+) y reasoning_effort "medium"/"xhigh"; "high" no existe.
curl -fsS "${AUTH[@]}" -H 'Content-Type: application/json' \
  "$BASE_URL/v1/chat/completions" -d @- <<JSON | pretty
{
  "model": "$MODEL",
  "messages": [
    {"role": "user", "content": "En una frase: ¿qué es un peso ternario {-1, 0, +1}?"}
  ],
  "max_tokens": $MAX_TOKENS,
  "temperature": 1.0,
  "top_p": 0.95${EXTRA_JSON}
}
JSON

echo
echo "OK: el endpoint responde en formato OpenAI."
