# qwen-opencode

Always-on local ollama server hosting `qwen3.5:9b-opencode` on `m4mac.local`, reachable from any LAN client. Tuned for [opencode](https://opencode.ai) — tool-calling works.

## What you get

- A tuned Qwen 3.5 9B model registered with ollama (vanilla `qwen3.5:9b-opencode`, or a slimmer Unsloth GGUF like `qwen3.5:9b-q3_k_s` — pick a path below).
- ollama listening on `127.0.0.1:11435` (loopback only) and a stdlib-python think-suppression proxy on `0.0.0.0:11434` (LAN-reachable). Both are LaunchAgents — they survive reboot, sleep, and crash, and the warmer pre-loads the model into memory at boot so the first request doesn't pay the 10–30 s cold start.
- `num_ctx=32768` and `OLLAMA_KEEP_ALIVE=-1` — model stays pinned, KV cache stays predictable. (16k used to be the default but opencode's prompt grew past it in late 2026 — see "Memory budget" for context.)
- An `opencode/opencode.json` listing both model variants so opencode can pick whichever is registered, plus an `AGENTS.md` of tool-use rules that opencode auto-loads.
- A 3-pane tmux test harness (`./test.sh`) that streams logs, runs 6 API smoke checks, and drops into opencode for an interactive tool-call test.

### Two endpoints

| Port | Bound to | Who calls it | What it does |
|---|---|---|---|
| `11434` | `0.0.0.0` (LAN) | opencode, your `curl`, any LAN client | Front door. Translates `/v1/chat/completions` to `/api/chat` with `think:false`, fake-streams via SSE keepalives, converts tool-call argument formats. Passes everything else straight through. |
| `11435` | `127.0.0.1` only | the proxy, the warmer, `ollama` CLI | Real ollama. You only hit this directly when you want to bypass the think-suppression (rare) or to run `ollama pull` (the proxy mishandles `/api/pull` NDJSON). |

## Two install paths

The same LaunchAgent + proxy stack runs both. They differ only in which model gets registered with ollama.

### Vanilla — for 16 GB+ hosts (the original M4 use case)

```sh
./install.sh   # idempotent — safe to re-run
./test.sh
```

`install.sh` will:
1. `brew install ollama` (skip if present)
2. `brew install anomalyco/tap/opencode` (skip if present)
3. Stop any competing ollama instance (Ollama.app or `brew services start ollama`)
4. Install the server LaunchAgent (ollama on `127.0.0.1:11435`)
5. Wait for the API to come up, pull `qwen3.5:9b`, build `qwen3.5:9b-opencode` from `Modelfile`
6. Install the proxy LaunchAgent (think:false shim on `:11434` — see "Proxy" section)
7. Install the warmer LaunchAgent (last, so it never warms a missing model)

Loads at ~9.5 GB resident, all-Metal — comfortable on 16 GB.

### Custom GGUF — for smaller hosts (e.g. 8 GB M2)

q4_K_M doesn't fit in 8 GB; weights split half-CPU and the model swap-thrashes (~0.1 tok/s, unusable). Workaround: register a slimmer Unsloth GGUF, then point the installer at it.

```sh
./setup-gguf.sh Q3_K_S                            # download + register one-shot
MODEL_TAG=qwen3.5:9b-q3_k_s ./install.sh          # wire it into the LaunchAgents
./test.sh
```

`setup-gguf.sh` pulls the requested quant from `unsloth/Qwen3.5-9B-GGUF` on Hugging Face (any tag from `Q2_K` through `Q8_0` plus the `UD-` Unsloth Dynamic 2.0 variants — `Q3_K_S` ≈ 4.3 GB, `UD-IQ2_M` ≈ 3.65 GB) and registers it as `qwen3.5:9b-<quant lowercased>`. The Modelfile template captures the `RENDERER qwen3.5` / `PARSER qwen3.5` directives copied verbatim from the official ollama Modelfile — without those, the GGUF emits `<|im_start|>` / `<|endoftext|>` as visible text.

Measured on M2 8 GB with `Q3_K_S` @ `num_ctx=32768`: 7.0 GB resident (5.13 GB Metal, 5.7 GB wired), ~9 tok/s sustained decode with `think:false` through the proxy. Swap pressure runs ~1.5–2.2 GB; macOS may grow the swap file from 2 GB to 3 GB during tool tests (persists until reboot).

`UD-IQ2_M` was evaluated for tool calling on 2026-04-29 and **rejected**: the 2-bit quant fits memory comfortably (3.65 GB on disk, ~5.07 GB Metal) but cannot reliably invoke opencode's tools — it emits the command/path as text instead. Stay on `Q3_K_S` for 8 GB hosts. See `CLAUDE.md` for the full comparison.

Switching paths later is just `MODEL_TAG=… ./install.sh` — the warmer plist is regenerated with the new tag and the agent re-bootstraps.

Re-running either flow is safe — every step detects whether it's already done.

## What `./test.sh` shows

A tmux session named `qwen-test` with three vertical panes:

- **top** — `tail -F` of `~/Library/Logs/ollama.log` and `ollama.err.log`. Request lines and runner state show up here in real time. (We don't use macOS `log stream` because the LaunchAgent redirects ollama's stdout/stderr to files via `StandardOutPath`, not via `os_log`.)
- **middle** — `tests/api.sh` runs once and prints six PASS/FAIL lines. Test #5 is the interesting one: it forces a `read_file` tool call against the OpenAI-compat endpoint and asserts that ollama returned a structured `tool_calls[0]` (not plain text). That's the test that catches the pre-v0.19.0 bug where qwen tool calls were emitted as text.
- **bottom** — `opencode` running with the local provider. The prompt *"Read prespec.md and tell me the model name it specifies"* is pre-typed; press Enter and watch a real read tool execute end-to-end.

`Ctrl-b` then arrow keys to move between panes, `Ctrl-b d` to detach (the session keeps running), `tmux attach -t qwen-test` to return.

## Files

```
qwen-opencode/
├── CLAUDE.md                                # design notes for future-me / agents
├── README.md                                # this file
├── AGENTS.md                                # opencode tool-use rules (auto-loaded by opencode)
├── prespec.md                               # original prespec
├── install.sh                               # idempotent installer (honours $MODEL_TAG)
├── setup-gguf.sh                            # one-shot GGUF download + register
├── test.sh                                  # opens tmux qwen-test session
├── Modelfile                                # vanilla path: FROM qwen3.5:9b
├── Modelfile.gguf.template                  # GGUF path: FROM __GGUF_PATH__
├── launchd/
│   ├── com.user.ollama.plist.template       # ollama server (127.0.0.1:11435)
│   ├── com.user.ollama-proxy.plist.template # think:false proxy (:11434)
│   └── com.user.ollama-warm.plist.template  # boot-time warmer (warms $MODEL_TAG)
├── opencode/
│   └── opencode.json                        # both vanilla and Q3_K_S models listed
├── proxy/
│   └── ollama_proxy.py                      # stdlib python think:false shim
└── tests/
    ├── api.sh                               # 6 curl checks (uses $(hostname) for LAN test)
    └── opencode.sh                          # launches opencode w/ pre-typed prompt
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

All examples assume you ran one of the install paths above. Replace `qwen3.5:9b-q3_k_s` with `qwen3.5:9b-opencode` if you're on the vanilla path. From a LAN device, replace `127.0.0.1` with the host's mDNS name (e.g. `m1mac.local`).

### OpenAI-compatible (what opencode and most SDKs hit)

The proxy on `:11434` translates this to `/api/chat` with `think:false` automatically — no thinking tokens, fast responses on a freshly-loaded model.

```sh
curl -s http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"qwen3.5:9b-q3_k_s",
    "messages":[{"role":"user","content":"Say hi in one sentence."}],
    "stream":false
  }' | python3 -m json.tool
```

### Native ollama `/api/chat` (full control)

`think:false` is the explicit knob. Equivalent to the proxied call above; useful when you want to test what the proxy is doing or experiment with `think:true`.

```sh
curl -s http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"qwen3.5:9b-q3_k_s",
    "messages":[{"role":"user","content":"Say hi in one sentence."}],
    "think":false,
    "stream":false
  }' | python3 -m json.tool
```

### Streaming

The proxy fake-streams `/v1/chat/completions`: it sends SSE `: keepalive` comments every 1 s while ollama generates, then dumps the full response as one `delta.content` chunk + `[DONE]`. The keepalives prevent intermediaries from timing out a long generation.

```sh
curl -N http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"qwen3.5:9b-q3_k_s",
    "messages":[{"role":"user","content":"Say hi"}],
    "stream":true
  }'
```

### Tool calls

This is the proof-of-life for opencode-style usage. The model returns a structured `tool_calls[0]`, not a JSON string in `content`. Test #5 in `tests/api.sh` runs exactly this and asserts the shape.

```sh
curl -s http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"qwen3.5:9b-q3_k_s",
    "messages":[{"role":"user","content":"Read the file prespec.md and tell me the model name it specifies."}],
    "tools":[{
      "type":"function",
      "function":{
        "name":"read_file",
        "description":"Read a file from the working directory.",
        "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
      }
    }],
    "tool_choice":"auto",
    "stream":false
  }' | python3 -m json.tool
```

### Bypassing the proxy

`:11435` is loopback-only and skips think-suppression. Use it for `ollama pull` (the proxy mishandles `/api/pull` NDJSON streaming) or to compare proxy-on vs proxy-off behaviour.

```sh
curl -s http://127.0.0.1:11435/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5:9b-q3_k_s","messages":[{"role":"user","content":"hi"}],"think":false,"stream":false}'
```

### Health and inspection

```sh
curl -s http://127.0.0.1:11434/api/version            # via proxy
curl -s http://127.0.0.1:11434/api/tags               # registered models
ollama ps                                              # is the model loaded? what's CONTEXT/SIZE?
ollama show qwen3.5:9b-q3_k_s --modelfile             # baked-in PARAMETERs
launchctl list | grep com.user.ollama                 # are the agents up?
```

### Switching models without re-running install.sh

The model the warmer pins is `MODEL_TAG` at install time. To switch:

```sh
MODEL_TAG=qwen3.5:9b-opencode ./install.sh   # back to vanilla
# or
./setup-gguf.sh UD-IQ2_M                      # register an even smaller quant
MODEL_TAG=qwen3.5:9b-ud-iq2_m ./install.sh
```

`install.sh` re-renders the warmer plist with the new tag and re-bootstraps the agent. The proxy and server agents stay loaded across switches.

### Thinking-mode notes

Two facts about Qwen 3.5 thinking that this stack is built around:
- ollama 0.22's OpenAI-compat layer (`/v1/chat/completions`) silently drops the `think:false` flag — it only works on `/api/chat`. The proxy translates `/v1` to `/api/chat` to dodge this.
- Qwen 3's `/think` / `/nothink` system-prompt directives are silently ignored on Qwen 3.5. There's no Modelfile `PARAMETER` for thinking either — it's strictly a per-request flag, which is why we need the proxy rather than baking it in.

## Uninstall

```sh
for label in com.user.ollama-warm com.user.ollama-proxy com.user.ollama; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
done
rm -f ~/Library/LaunchAgents/com.user.ollama*.plist
ollama rm qwen3.5:9b-opencode 2>/dev/null
ollama rm qwen3.5:9b-q3_k_s 2>/dev/null
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
| `num_ctx` | `32768` | floor for reliable opencode tool calls (bumped from 16384 on 2026-04-29 — opencode's prompt grew past 16k). See trade-offs below |
| `OLLAMA_KEEP_ALIVE` | `-1` | never unload — defeats ollama's memory-saving auto-eviction |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | predictable footprint |
| `OLLAMA_NUM_PARALLEL` | `1` | predictable footprint |
| `OLLAMA_FLASH_ATTENTION` | `1` | perf gain on Apple Silicon |

### Context window trade-offs

`num_ctx` directly controls KV cache size — the biggest non-weights memory cost. For `qwen3.5:9b` Q4_K_M with FlashAttention on Metal:

| `num_ctx` | KV cache | Total resident | Free RAM after model | Verdict |
|---|---|---|---|---|
| `8192` | ~0.85 GiB | ~7.6 GiB | ~7.6 GB | **Avoid** — below opencode's tool-calling floor |
| `16384` | ~1.7 GiB | **~8.4 GiB** | **~6.5 GB** | **Broken for opencode** — prompt saturates at input=16384, output=2 |
| `32768` | ~2.2 GiB | ~9.1 GiB | ~5.8 GB | **Default.** Floor for reliable opencode tool calls (verified 2026-04-29) |
| `65536+` | 4+ GiB | 11+ GiB | <4 GB | **Don't.** Forces severe swap on 16 GB |

**Decision rule: pick `32768`.** 16384 used to be the floor; opencode's prompt grew past it. Above 32768 the math stops working on 16 GB.

To switch to 32K (more headroom for opencode multi-file work, less headroom for everything else): edit `Modelfile`, set `PARAMETER num_ctx 32768`, then:

```sh
ollama create qwen3.5:9b-opencode -f Modelfile
# force-evict the old resident copy:
curl -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5:9b-opencode","keep_alive":0}'
# warm the new one (think:false to avoid 30s thinking on the warm request):
curl -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5:9b-opencode","prompt":"hi","think":false,"stream":false,"keep_alive":-1}'
```

### Quantization

The vanilla path uses `q4_K_M` — that's what `qwen3.5:9b` ships as on ollama. There is no smaller variant on ollama's library (verified 2026-04-29: `ollama pull qwen3.5:9b-q4_K_S` returns "manifest does not exist"). For smaller quants — needed if you don't have 16 GB — use the **GGUF path** documented at the top of this README; `setup-gguf.sh` pulls from `unsloth/Qwen3.5-9B-GGUF` on Hugging Face (Q3_K_S, Q3_K_M, UD-IQ2_M, etc).

## Troubleshooting

**"Test #5 fails: tool call returns as text in `content`."** Your ollama is older than v0.19.0. `brew upgrade ollama && launchctl kickstart -k gui/$(id -u)/com.user.ollama`.

**"Test #6 fails: m4mac.local unreachable."** Either Bonjour (mDNS) isn't resolving, or the macOS firewall is blocking inbound :11434. Try `dns-sd -G v4 m4mac.local` from a LAN client. On the M4, accept the firewall prompt the first time a request comes in.

**"opencode says no model found."** Confirm `OPENCODE_CONFIG` points at `opencode/opencode.json` (or that you copied its contents into `~/.config/opencode/opencode.json`), and that the model name is `qwen3.5:9b-opencode` exactly (the trailing `-opencode` is the tuned variant; the bare `qwen3.5:9b` doesn't have the Modelfile params).

**"Two ollamas fighting for :11434."** `install.sh` should have stopped the official Ollama.app and `brew services` versions, but if you started them after install: `osascript -e 'tell application "Ollama" to quit'; brew services stop ollama; launchctl kickstart -k gui/$(id -u)/com.user.ollama`.
