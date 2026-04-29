#!/usr/bin/env bash
# setup-gguf.sh — download an Unsloth Qwen3.5-9B GGUF and register it
# with ollama as a tuned model. Idempotent: re-running with the same
# quant skips the download and rebuilds the model.
#
# Usage:
#   ./setup-gguf.sh                # default: Q3_K_S
#   ./setup-gguf.sh Q4_K_M         # any quant from unsloth/Qwen3.5-9B-GGUF
#   ./setup-gguf.sh UD-IQ2_M       # Unsloth Dynamic 2.0 variants too
#
# Env vars:
#   OLLAMA_TAG     name to register (default: qwen3.5:9b-<quant lowercased>)
#   DOWNLOAD_DIR   where to keep the .gguf (default: /tmp/qwen-ggufs)
#   HF_REPO        source repo (default: unsloth/Qwen3.5-9B-GGUF)
#
# Why this exists: ollama's library only ships q4_K_M (6.6 GB) and bigger.
# On 8 GB hardware that doesn't fit; smaller quants (Q3_K_S ~4.3 GB,
# UD-IQ2_M ~3.65 GB) come from Unsloth's HF repo. The Modelfile template
# captures the upstream chat renderer so we don't need to keep the 6.6 GB
# base model around just for its Modelfile metadata.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$REPO_ROOT/Modelfile.gguf.template"

QUANT="${1:-Q3_K_S}"
HF_REPO="${HF_REPO:-unsloth/Qwen3.5-9B-GGUF}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/qwen-ggufs}"

# Default tag: qwen3.5:9b-<quant lowercased, dashes preserved>
QUANT_LOWER="$(printf "%s" "$QUANT" | tr '[:upper:]' '[:lower:]')"
TAG="${OLLAMA_TAG:-qwen3.5:9b-${QUANT_LOWER}}"

GGUF_FILENAME="Qwen3.5-9B-${QUANT}.gguf"
GGUF_URL="https://huggingface.co/${HF_REPO}/resolve/main/${GGUF_FILENAME}"
GGUF_PATH="${DOWNLOAD_DIR}/${GGUF_FILENAME}"

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

[[ -f "$TEMPLATE" ]] || { red "missing template: $TEMPLATE"; exit 1; }
command -v ollama >/dev/null || { red "ollama not on PATH"; exit 1; }
command -v curl >/dev/null   || { red "curl not on PATH"; exit 1; }

# Ollama daemon must be reachable (uses default :11434 unless OLLAMA_HOST set).
if ! curl -fsS "${OLLAMA_HOST:-http://127.0.0.1:11434}/api/version" >/dev/null 2>&1; then
    red "ollama daemon not responding at ${OLLAMA_HOST:-http://127.0.0.1:11434}"
    red "  start it via the qwen-opencode LaunchAgent, or 'ollama serve' in another shell"
    exit 1
fi

cyan "==> quant : $QUANT"
cyan "==> tag   : $TAG"
cyan "==> source: $GGUF_URL"

mkdir -p "$DOWNLOAD_DIR"
if [[ -f "$GGUF_PATH" ]]; then
    cyan "==> download: skip (exists, $(du -h "$GGUF_PATH" | cut -f1))"
else
    cyan "==> downloading $GGUF_FILENAME ..."
    if ! curl -L -f -# -o "$GGUF_PATH" "$GGUF_URL"; then
        red "download failed — check that '$GGUF_FILENAME' exists at:"
        red "  https://huggingface.co/${HF_REPO}/tree/main"
        rm -f "$GGUF_PATH"
        exit 1
    fi
    green "    downloaded ($(du -h "$GGUF_PATH" | cut -f1))"
fi

# Render Modelfile from template.
RENDERED="${DOWNLOAD_DIR}/Modelfile.${QUANT}"
sed "s|__GGUF_PATH__|${GGUF_PATH}|g" "$TEMPLATE" > "$RENDERED"

cyan "==> ollama create $TAG"
ollama create "$TAG" -f "$RENDERED"
green "    created"

cyan "==> result"
ollama list | awk -v tag="$TAG" 'NR==1 || $1==tag {print "    "$0}'

echo
green "next: try a call"
echo "  curl -s http://127.0.0.1:11434/api/chat \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$TAG\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"think\":false,\"stream\":false}'"
