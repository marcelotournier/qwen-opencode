#!/usr/bin/env bash
# Idempotent installer for qwen-opencode.
# Re-run any time — each section detects whether it's already done.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
LAUNCHAGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
OLLAMA_URL="http://127.0.0.1:11434"
BASE_MODEL="qwen3.5:9b"
TUNED_MODEL="qwen3.5:9b-opencode"

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
    # Ollama.app (the official desktop app) competes for :11434.
    if pgrep -f "Ollama.app" >/dev/null 2>&1; then
        yellow "    Ollama.app is running — quitting"
        osascript -e 'tell application "Ollama" to quit' 2>/dev/null || true
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
        "$src" > "$tmp"

    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        skip "$name.plist unchanged"
    else
        mv "$tmp" "$dst"
        done_ "$name.plist written"
    fi

    # Re-bootstrap so any change takes effect. bootout is allowed to fail
    # (it errors when not loaded). bootstrap must succeed.
    launchctl bootout "gui/$(id -u)/${name}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$dst"
    done_ "$name loaded"
}

wait_for_ollama() {
    cyan "    waiting for ollama on $OLLAMA_URL ..."
    local i
    for i in $(seq 1 60); do
        if curl -fsS "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
            done_ "ollama responding (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    red "ollama did not start within 60s — check $LOGS/ollama.err.log"
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

step "Wait for server"
wait_for_ollama

step "Pull base model: $BASE_MODEL"
if have_model "$BASE_MODEL"; then
    skip "$BASE_MODEL already pulled"
else
    ollama pull "$BASE_MODEL"
    done_ "$BASE_MODEL pulled"
fi

step "Build tuned model: $TUNED_MODEL"
if have_model "$TUNED_MODEL"; then
    skip "$TUNED_MODEL already built"
else
    ollama create "$TUNED_MODEL" -f "$REPO_ROOT/Modelfile"
    done_ "$TUNED_MODEL created"
fi

step "Install LaunchAgent: com.user.ollama-warm (boot warmer)"
install_plist com.user.ollama-warm

step "Done"
green "qwen-opencode is up. Try:"
green "  curl $OLLAMA_URL/api/tags | grep $TUNED_MODEL"
green "  ./test.sh"
