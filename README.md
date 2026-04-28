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

`./install.sh` will:
1. `brew install ollama` (skip if present)
2. `brew install anomalyco/tap/opencode` (skip if present)
3. Stop any competing ollama instance (Ollama.app or `brew services start ollama`)
4. Install the server LaunchAgent and bootstrap it
5. Wait for the API to come up, pull `qwen3.5:9b`, build `qwen3.5:9b-opencode` from the Modelfile
6. Install the warmer LaunchAgent (last, so it never warms a missing model)

Re-running it is safe — every step detects whether it's already done.

## What `./test.sh` shows

A tmux session named `qwen-test` with three vertical panes:

- **top** — `tail -F` of `~/Library/Logs/ollama.log` and `ollama.err.log`. Request lines and runner state show up here in real time. (We don't use macOS `log stream` because the LaunchAgent redirects ollama's stdout/stderr to files via `StandardOutPath`, not via `os_log`.)
- **middle** — `tests/api.sh` runs once and prints six PASS/FAIL lines. Test #5 is the interesting one: it forces a `read_file` tool call against the OpenAI-compat endpoint and asserts that ollama returned a structured `tool_calls[0]` (not plain text). That's the test that catches the pre-v0.19.0 bug where qwen tool calls were emitted as text.
- **bottom** — `opencode` running with the local provider. The prompt *"Read prespec.md and tell me the model name it specifies"* is pre-typed; press Enter and watch a real read tool execute end-to-end.

`Ctrl-b` then arrow keys to move between panes, `Ctrl-b d` to detach (the session keeps running), `tmux attach -t qwen-test` to return.

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
          "name": "Qwen 3.5 9B (m4mac, tool-tuned)",
          "tools": true
        }
      }
    }
  }
}
```

That's all that differs from the M4-local config: the `baseURL` points to `m4mac.local` instead of `localhost`. Note `"tools": true` — without it, opencode's planning works but file edits silently no-op. Per the [kdnuggets opencode + ollama guide](https://www.kdnuggets.com/seeing-whats-possible-with-opencode-ollama-qwen3-coder), this is the most common opencode-with-local-ollama misconfiguration.

## Curl examples

The model has thinking mode on by default. Without disabling it, even a one-word answer can take 10–60 s on the M4 because the model emits hundreds of internal `<think>` tokens before the visible response. There are two paths to fast responses:

```sh
# /api/chat — native ollama endpoint, supports `think: false`
curl -s http://m4mac.local:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.5:9b-opencode",
    "messages": [{"role":"user","content":"Say hi in one short sentence."}],
    "think": false,
    "stream": false
  }' | python3 -m json.tool
# ~0.5 s on the M4
```

If you're stuck with `/v1/chat/completions` (anything OpenAI-SDK-shaped, including opencode), there is no working thinking toggle on ollama 0.22 — verified against four candidate spellings:

| What we tried on `/v1/chat/completions` | Result |
| --- | --- |
| `"chat_template_kwargs": {"enable_thinking": false}` | thinking on (485 tokens, 37 s) |
| `"extra_body": {"chat_template_kwargs": {"enable_thinking": false}}` | timed out at 60 s |
| `"enable_thinking": false` (top-level) | thinking on (779 tokens, 59 s) |
| `"think": false` (top-level) | thinking on (609 tokens, 47 s) |

ollama strips unknown fields at the OpenAI-compat layer. Per the qwen3.5 issue threads, fixing this requires an ollama change. Until then, use `/api/chat` from any caller you control.

Notes:
- The Qwen 3 `/think` and `/nothink` system-prompt directives **don't work** on Qwen 3.5 either — the directive is silently ignored and the model thinks anyway.
- Modelfile `PARAMETER` doesn't include a thinking toggle — there is no way to bake "thinking off" into the model tag. It's a per-request flag.
- This means **opencode (which uses `/v1/chat/completions`) will pay the thinking-tokens latency** until either ollama exposes the toggle on the compat layer or opencode adds a passthrough. We accept that trade for now.

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
- **Logs**: `~/Library/Logs/ollama.log` and `~/Library/Logs/ollama.err.log` (server); `~/Library/Logs/ollama-warm.log` (warmer).
- **No auth, no TLS**: trusted home LAN only. Don't expose `:11434` to the public internet.
- **Sleep**: `OLLAMA_KEEP_ALIVE=-1` should hold the model resident across sleep, but if macOS evicts it, the next request reloads it (~10–30 s).

## Memory budget

The M4 has 16 GB unified memory. The server holds the model resident, so we cap context aggressively:

| Setting | Value | Why |
| --- | --- | --- |
| `num_ctx` | `32768` | opencode-recommended floor for reliable tool calls; larger contexts blow the KV cache |
| `OLLAMA_KEEP_ALIVE` | `-1` | never unload — defeats ollama's memory-saving auto-eviction |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | predictable footprint |
| `OLLAMA_NUM_PARALLEL` | `1` | predictable footprint |
| `OLLAMA_FLASH_ATTENTION` | `1` | perf gain on Apple Silicon |

Measured resident with the model fully loaded and 32K context allocated: **~9.7 GB** (Q4_K_M, all in unified memory). That leaves roughly 6 GB for macOS and other apps on the 16 GB M4 — workable, but not a lot of headroom. If you find yourself swapping, drop `num_ctx` to `16384` in `Modelfile` and rebuild.

## Troubleshooting

**"Test #5 fails: tool call returns as text in `content`."** Your ollama is older than v0.19.0. `brew upgrade ollama && launchctl kickstart -k gui/$(id -u)/com.user.ollama`.

**"Test #6 fails: m4mac.local unreachable."** Either Bonjour (mDNS) isn't resolving, or the macOS firewall is blocking inbound :11434. Try `dns-sd -G v4 m4mac.local` from a LAN client. On the M4, accept the firewall prompt the first time a request comes in.

**"opencode says no model found."** Confirm `OPENCODE_CONFIG` points at `opencode/opencode.json` (or that you copied its contents into `~/.config/opencode/opencode.json`), and that the model name is `qwen3.5:9b-opencode` exactly (the trailing `-opencode` is the tuned variant; the bare `qwen3.5:9b` doesn't have the Modelfile params).

**"Two ollamas fighting for :11434."** `install.sh` should have stopped the official Ollama.app and `brew services` versions, but if you started them after install: `osascript -e 'tell application "Ollama" to quit'; brew services stop ollama; launchctl kickstart -k gui/$(id -u)/com.user.ollama`.
