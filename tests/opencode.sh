#!/usr/bin/env bash
# Launch opencode pointed at the local ollama provider.
# test.sh sends a starter prompt via tmux send-keys after this comes up.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OPENCODE_CONFIG="$REPO_ROOT/opencode/opencode.json"

cat <<EOF
launching opencode with:
  OPENCODE_CONFIG=$OPENCODE_CONFIG
  model=qwen3.5:9b-opencode

When opencode is ready, the test harness pre-types this prompt:
  > Read prespec.md and tell me the model name it specifies

Press Enter to send it. Watch for an actual read_file (or equivalent)
tool invocation — that's the end-to-end proof of tool calling.

EOF

cd "$REPO_ROOT"
exec opencode -m ollama/qwen3.5:9b-opencode
