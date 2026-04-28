# qwen-opencode

Always-on local ollama server hosting `qwen3.5:9b-opencode` on `m4mac.local`, reachable from any LAN client. Tuned for [opencode](https://opencode.ai) — tool-calling works.

## What you get

- `qwen3.5:9b` (6.6 GB, 256K-capable) re-tagged as `qwen3.5:9b-opencode` with sampling params baked in via `Modelfile`.
- ollama bound to `0.0.0.0:11434`, so any device on the LAN can call it via `m4mac.local:11434`.
- Two LaunchAgents: one keeps the ollama server running across reboot/sleep/crash, the other pre-warms the model into memory at boot so the first request doesn't pay a 10–30 s cold start.
- Capped `num_ctx=32768` and `OLLAMA_KEEP_ALIVE=-1` so the model stays resident in ~7–9 GB without thrashing macOS swap on the 16 GB M4.
- An `opencode/opencode.json` that points opencode at the local model out of the box.
- A 3-pane tmux test harness (`./test.sh`) that streams logs, runs 6 API smoke checks, and drops into opencode for an interactive tool-call test.

## Quick start (M4 host only)

```sh
./install.sh   # idempotent — safe to re-run
./test.sh      # tmux session "qwen-test" with logs + smoke + opencode
```

## Files

```
qwen-opencode/
├── CLAUDE.md                           # design notes for future-me / agents
├── README.md                           # this file
├── prespec.md                          # original prespec
├── install.sh                          # idempotent installer
├── test.sh                             # opens tmux qwen-test session
├── Modelfile                           # qwen3.5:9b-opencode definition
├── launchd/
│   ├── com.user.ollama.plist.template       # ollama server agent
│   └── com.user.ollama-warm.plist.template  # boot-time warmer
├── opencode/
│   └── opencode.json                   # opencode → local ollama provider
└── tests/
    ├── api.sh                          # 6 curl checks (run inside tmux)
    └── opencode.sh                     # launches opencode w/ pre-typed prompt
```

## LAN clients

LAN install is intentionally manual — see [LAN client setup](#lan-client-setup) below.

## LAN client setup

Other devices on the home network reach the server at `http://m4mac.local:11434`. To use it from opencode on another machine, drop this into `~/.config/opencode/opencode.json` (or pass via `OPENCODE_CONFIG`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (m4mac)",
      "options": {
        "baseURL": "http://m4mac.local:11434/v1"
      },
      "models": {
        "qwen3.5:9b-opencode": {
          "name": "Qwen 3.5 9B (m4mac, tool-tuned)"
        }
      }
    }
  }
}
```

That's all that differs from the M4-local config: the `baseURL` points to `m4mac.local` instead of `localhost`.

## Uninstall

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.ollama.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.ollama-warm.plist
rm ~/Library/LaunchAgents/com.user.ollama*.plist
brew uninstall ollama opencode
```

## Operational notes

- **macOS firewall**: the first inbound LAN connection triggers an "Allow incoming connections?" prompt — accept it once.
- **Auto-login**: LaunchAgents only run after login. If auto-login is off on the M4, ollama is unreachable until someone logs in.
- **Logs**: `~/Library/Logs/ollama.log` and `~/Library/Logs/ollama.err.log`.
- **No auth, no TLS**: trusted home LAN only. Don't expose `:11434` to the public internet.
