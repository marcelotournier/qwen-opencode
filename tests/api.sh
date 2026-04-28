#!/usr/bin/env bash
# 6 smoke checks against the local ollama server.
# Run from anywhere — paths resolve to repo root.

set -u

OLLAMA_LOCAL="http://127.0.0.1:11434"
OLLAMA_LAN="http://m4mac.local:11434"
MODEL="qwen3.5:9b-opencode"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0

green() { printf "\033[32m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }
bold()  { printf "\033[1m%s\033[0m" "$*"; }

check() {
    local name="$1"; shift
    printf "  %-60s " "$name"
    if "$@"; then
        echo "$(green PASS)"
        pass=$((pass+1))
    else
        echo "$(red FAIL)"
        fail=$((fail+1))
    fi
}

# Each helper returns 0=pass, 1=fail.
# JSON bodies are passed to python via $BODY env var to avoid shell-quoting hell.

t1_version() {
    local code
    code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$OLLAMA_LOCAL/api/version") || return 1
    [[ "$code" == "200" ]]
}

t2_tags() {
    curl -fsS -m 5 "$OLLAMA_LOCAL/api/tags" | grep -q "\"name\":\"$MODEL\""
}

t3_generate_native() {
    local body
    body=$(curl -fsS -m 60 -X POST "$OLLAMA_LOCAL/api/generate" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with the single word: pong\",\"stream\":false}") || return 1
    BODY="$body" python3 - <<'PY' 2>/dev/null
import json, os, sys
d = json.loads(os.environ["BODY"])
sys.exit(0 if d.get("response", "").strip() else 1)
PY
}

t4_chat_openai_compat() {
    local body
    body=$(curl -fsS -m 60 -X POST "$OLLAMA_LOCAL/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: pong\"}]}") || return 1
    BODY="$body" python3 - <<'PY' 2>/dev/null
import json, os, sys
d = json.loads(os.environ["BODY"])
content = d.get("choices", [{}])[0].get("message", {}).get("content", "")
sys.exit(0 if content.strip() else 1)
PY
}

t5_tool_call() {
    # Force the model to use a tool. With the v0.19.0 fix, ollama parses
    # qwen's tool-call output and returns it in tool_calls; without the fix
    # it ends up as plain text in content.
    local body
    body=$(curl -fsS -m 90 -X POST "$OLLAMA_LOCAL/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        --data @- <<JSON
{
  "model": "$MODEL",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant. When the user asks about a file, call read_file. Do not answer from memory."},
    {"role": "user", "content": "What does prespec.md say? Use the read_file tool with path \"prespec.md\"."}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read a file from the filesystem and return its contents.",
      "parameters": {
        "type": "object",
        "properties": {"path": {"type": "string", "description": "Path to the file"}},
        "required": ["path"]
      }
    }
  }],
  "tool_choice": "auto"
}
JSON
) || return 1

    BODY="$body" python3 - <<'PY' 2>/dev/null
import json, os, sys
d = json.loads(os.environ["BODY"])
msg = d.get("choices", [{}])[0].get("message", {})
calls = msg.get("tool_calls") or []
if not calls:
    sys.exit(1)
fn = calls[0].get("function", {})
if fn.get("name") != "read_file":
    sys.exit(1)
args = fn.get("arguments", "")
try:
    parsed = json.loads(args) if isinstance(args, str) else args
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(parsed, dict) and "path" in parsed else 1)
PY
}

t6_lan_reachable() {
    local code
    code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$OLLAMA_LAN/api/version" 2>/dev/null) || return 1
    [[ "$code" == "200" ]]
}

echo
bold "qwen-opencode API smoke tests"; echo
echo "  endpoint:  $OLLAMA_LOCAL"
echo "  model:     $MODEL"
echo "  repo:      $REPO_ROOT"
echo

check "1. GET /api/version returns 200"                       t1_version
check "2. /api/tags lists $MODEL"                             t2_tags
check "3. POST /api/generate (native) returns non-empty"      t3_generate_native
check "4. POST /v1/chat/completions returns non-empty"        t4_chat_openai_compat
check "5. Tool call: read_file invoked with parseable args"   t5_tool_call
check "6. LAN: m4mac.local:11434/api/version returns 200"     t6_lan_reachable

echo
if [[ $fail -eq 0 ]]; then
    bold "$(green "all $pass passed")"; echo
    exit 0
else
    bold "$(red "$fail failed, $pass passed")"; echo
    exit 1
fi
