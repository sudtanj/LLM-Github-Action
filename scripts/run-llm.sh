#!/usr/bin/env bash
#
# Runs one Ollama chat completion and reports the result back to the gateway
# that dispatched this workflow run, success or failure. A trap on EXIT
# guarantees the callback always fires exactly once -- the gateway is holding
# an HTTP request open waiting on it, and the only alternative to reporting a
# failure explicitly is the gateway's own timeout, which is much slower and
# gives the caller no reason why.
#
# Usage: run-llm.sh REQUEST_ID CALLBACK_URL CALLBACK_TOKEN MODEL MESSAGES_FILE
set -uo pipefail

REQUEST_ID="$1"
CALLBACK_URL="$2"
CALLBACK_TOKEN="$3"
MODEL="$4"
MESSAGES_FILE="$5"

COMPLETION_FILE="$(mktemp)"
ERROR_MSG=""

send_callback() {
  local completion_json="null"
  local error_json="null"

  if [[ -s "$COMPLETION_FILE" ]] && jq -e . "$COMPLETION_FILE" >/dev/null 2>&1; then
    completion_json="$(cat "$COMPLETION_FILE")"
  fi
  if [[ -n "$ERROR_MSG" ]]; then
    error_json="$(jq -n --arg m "$ERROR_MSG" '$m')"
  fi

  jq -n \
    --arg request_id "$REQUEST_ID" \
    --argjson completion "$completion_json" \
    --argjson error "$error_json" \
    '{request_id: $request_id, completion: $completion, error: $error}' \
    | curl -sS --max-time 30 -X POST "$CALLBACK_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $CALLBACK_TOKEN" \
        --data-binary @- -o /tmp/callback-response.json -w '\ncallback HTTP %{http_code}\n' \
    || echo "::warning::callback POST to $CALLBACK_URL failed"

  rm -f "$COMPLETION_FILE"
}
trap send_callback EXIT

echo "Starting Ollama server..."
ollama serve >/tmp/ollama-serve.log 2>&1 &

ready=""
for _ in $(seq 1 60); do
  if curl -sf http://127.0.0.1:11434/ >/dev/null 2>&1; then
    ready="1"
    break
  fi
  sleep 1
done
if [[ -z "$ready" ]]; then
  ERROR_MSG="Ollama server did not become ready in time. Log tail: $(tail -c 2000 /tmp/ollama-serve.log 2>/dev/null)"
  exit 1
fi

echo "Pulling model $MODEL..."
if ! ollama pull "$MODEL"; then
  ERROR_MSG="Failed to pull model \"$MODEL\"."
  exit 1
fi

if ! jq -e . "$MESSAGES_FILE" >/dev/null 2>&1; then
  ERROR_MSG="messages payload was not valid JSON."
  exit 1
fi

REQUEST_BODY="$(jq -n --arg model "$MODEL" --slurpfile messages "$MESSAGES_FILE" \
  '{model: $model, messages: $messages[0], stream: false}')"

echo "Running chat completion..."
HTTP_CODE="$(curl -sS --max-time 600 -o "$COMPLETION_FILE" -w '%{http_code}' \
  http://127.0.0.1:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY")"

if [[ "$HTTP_CODE" != "200" ]]; then
  ERROR_MSG="Ollama returned HTTP $HTTP_CODE: $(cat "$COMPLETION_FILE" 2>/dev/null | head -c 2000)"
  : > "$COMPLETION_FILE"
  exit 1
fi

echo "Completion succeeded."
