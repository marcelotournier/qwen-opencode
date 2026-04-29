#!/usr/bin/env bash
# Idempotent installer for qwen-opencode.
# Re-run any time — each section detects whether it's already done.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
# Upstream ollama lives on :11435; the proxy fronts :11434 for clients.
# install-time operations (pull, model build) talk to upstream directly —
# the proxy mishandles /api/pull NDJSON streams (see CLAUDE.md).
OLLAMA_URL="http://127.0.0.1:11435"
PROXY_URL="http://127.0.0.1:11434"
BASE_MODEL="qwen3.5:9b"
DEFAULT_TUNED_MODEL="qwen3.5:9b-opencode"

# MODEL_TAG selects which ollama model the LaunchAgent warmer pins and
# what opencode points at. Two supported flows:
#   1. Vanilla   (default) — pull qwen3.5:9b, build qwen3.5:9b-opencode
#                            from Modelfile. Needs ~16 GB RAM.
#   2. Custom GGUF         — register a smaller quant via setup-gguf.sh
#                            FIRST, then pass MODEL_TAG=qwen3.5:9b-q3_k_s
#                            (or whichever) to this installer. Required
#                            on smaller hosts where q4_K_M doesn't fit.
MODEL_TAG="${MODEL_TAG:-$DEFAULT_TUNED_MODEL}"

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }
step()  { cyan ""; cyan "==> $*"; }
skip()  { yellow "    skip: $*"; }
done_() { green "    ok:   $*"; }

require_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || { red "macOS only"; exit 1; }
}

require_brew() {
    command -v brew >/dev/null || { red "Homebrew required: https://brew.sh"; exit 1; }
}

install_brew_pkg() {
    local pkg="$1" tap_pkg="${2:-$1}"
    if brew list --formula "$pkg" >/dev/null 2>&1 || brew list --cask "$pkg" >/dev/null 2>&1; then
        skip "$pkg already installed"
    else
        cyan "    brew install $tap_pkg"
        brew install "$tap_pkg"
        done_ "$pkg installed"
    fi
}

stop_competing_ollama() {
    # Ollama.app (the official desktop app) competes for :11434 and tends
    # to auto-relaunch after `osascript quit`, so also bootout its agent
    # and pkill any survivors.
    if launchctl list 2>/dev/null | grep -q com.ollama.ollama; then
        yellow "    Ollama.app launchd agent loaded — booting out"
        launchctl bootout "gui/$(id -u)/com.ollama.ollama" 2>/dev/null || true
    fi
    if pgrep -f "Ollama.app" >/dev/null 2>&1; then
        yellow "    Ollama.app is running — quitting"
        osascript -e 'tell application "Ollama" to quit' 2>/dev/null || true
        sleep 1
        pkill -f "Ollama.app/Contents" 2>/dev/null || true
        sleep 1
    fi
    # `brew services start ollama` would install ~/Library/LaunchAgents/homebrew.mxcl.ollama.plist
    if launchctl list 2>/dev/null | grep -q homebrew.mxcl.ollama; then
        yellow "    brew services ollama running — stopping"
        brew services stop ollama >/dev/null 2>&1 || true
    fi
}

install_plist() {
    local name="$1"
    local src="$REPO_ROOT/launchd/${name}.plist.template"
    local dst="$LAUNCHAGENTS/${name}.plist"
    [[ -f "$src" ]] || { red "missing template: $src"; exit 1; }

    mkdir -p "$LAUNCHAGENTS" "$LOGS"
    local tmp="${dst}.tmp"
    sed -e "s|__USER__|$USER|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__BREW_PREFIX__|$BREW_PREFIX|g" \
        -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
        -e "s|__MODEL_TAG__|$MODEL_TAG|g" \
        "$src" > "$tmp"

    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        skip "$name.plist unchanged"
        # Already-loaded agents stay loaded; just make sure it IS loaded.
        if ! launchctl list 2>/dev/null | awk '{print $NF}' | grep -qx "$name"; then
            launchctl bootstrap "gui/$(id -u)" "$dst"
            done_ "$name (re)loaded"
        fi
    else
        mv "$tmp" "$dst"
        done_ "$name.plist written"
        # Content changed — bounce the agent.
        launchctl bootout "gui/$(id -u)/${name}" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$dst"
        done_ "$name loaded"
    fi
}

wait_for_url() {
    local label="$1" url="$2" logfile="$3"
    cyan "    waiting for $label on $url ..."
    local i
    for i in $(seq 1 60); do
        if curl -fsS "$url/api/version" >/dev/null 2>&1; then
            done_ "$label responding (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    red "$label did not start within 60s — check $logfile"
    exit 1
}

have_model() {
    curl -fsS "$OLLAMA_URL/api/tags" 2>/dev/null \
        | grep -q "\"name\":\"$1\""
}

#-----------------------------------------------------------------------
step "Preflight"
require_macos
require_brew
done_ "macOS + Homebrew detected (prefix: $BREW_PREFIX)"

step "Install ollama"
install_brew_pkg ollama

step "Install opencode"
if brew list opencode >/dev/null 2>&1; then
    skip "opencode already installed"
else
    cyan "    brew install anomalyco/tap/opencode"
    brew install anomalyco/tap/opencode
    done_ "opencode installed"
fi

step "Stop competing ollama instances"
stop_competing_ollama
done_ "no competitors"

step "Install LaunchAgent: com.user.ollama (server)"
install_plist com.user.ollama

step "Wait for server (upstream :11435)"
wait_for_url "ollama" "$OLLAMA_URL" "$LOGS/ollama.err.log"

# `ollama` CLI honours OLLAMA_HOST — point it at the upstream so pull/create
# bypass the proxy (which mishandles /api/pull NDJSON; see CLAUDE.md).
export OLLAMA_HOST="127.0.0.1:11435"

step "Ensure model: $MODEL_TAG"
if have_model "$MODEL_TAG"; then
    skip "$MODEL_TAG already in ollama registry"
elif [[ "$MODEL_TAG" == "$DEFAULT_TUNED_MODEL" ]]; then
    # Vanilla path: pull qwen3.5:9b, build qwen3.5:9b-opencode from Modelfile.
    if have_model "$BASE_MODEL"; then
        skip "$BASE_MODEL already pulled"
    else
        ollama pull "$BASE_MODEL"
        done_ "$BASE_MODEL pulled"
    fi
    ollama create "$MODEL_TAG" -f "$REPO_ROOT/Modelfile"
    done_ "$MODEL_TAG created from Modelfile"
else
    # Custom MODEL_TAG that doesn't exist — caller should have run
    # setup-gguf.sh first. We don't auto-pull because we don't know
    # what GGUF or quant they meant.
    red "model '$MODEL_TAG' is not in the ollama registry."
    red "  if you meant to use a custom GGUF variant, register it first:"
    red "    ./setup-gguf.sh <quant>      # e.g. Q3_K_S, UD-IQ2_M"
    red "  then re-run with MODEL_TAG=$MODEL_TAG ./install.sh"
    exit 1
fi

step "Install LaunchAgent: com.user.ollama-proxy (think:false shim, binds :11434)"
install_plist com.user.ollama-proxy

step "Wait for proxy (front-door :11434)"
wait_for_url "proxy" "$PROXY_URL" "$LOGS/ollama-proxy.err.log"

step "Install LaunchAgent: com.user.ollama-warm (boot warmer)"
install_plist com.user.ollama-warm

step "Done"
green "qwen-opencode is up (model: $MODEL_TAG). Try:"
green "  curl $OLLAMA_URL/api/tags | grep $MODEL_TAG"
green "  ./test.sh"
