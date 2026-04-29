# qwen-opencode

Always-on local ollama server hosting `qwen3.5:9b` for opencode and other LAN clients.

## Topology

- **Host**: `m4mac.local` — Apple M4, 16 GB unified memory, Metal 4. This is the *only* host. LAN clients are out of scope for install scripts.
- **Model**: pulled as `qwen3.5:9b` from the ollama library (6.6 GB, 256K-capable), then re-tagged as `qwen3.5:9b-opencode` after baking in tuned params via Modelfile.
- **Server binding**: `OLLAMA_HOST=0.0.0.0:11434`. No auth — trusted home LAN. Reachable from other LAN devices via Bonjour at `m4mac.local:11434`.
- **opencode**: installed on the M4 only, used for the tmux smoke test. Other LAN clients install opencode manually later.

## Implementation paths

Two ways to get the tuned model into ollama. Both terminate in a `MODEL_TAG` that the LaunchAgent warmer pins and that opencode points at; the LaunchAgent + proxy stack is identical.

### Vanilla (default — 16 GB+ hosts)

```sh
./install.sh                 # uses MODEL_TAG=qwen3.5:9b-opencode
```

Pulls `qwen3.5:9b` (6.6 GB, q4_K_M) from ollama's library, builds `qwen3.5:9b-opencode` via `Modelfile`. ~9.5 GB resident on a 16 GB M4 with 100% Metal residency.

### Custom GGUF (smaller hosts, or anyone wanting a different quant)

```sh
./setup-gguf.sh Q3_K_S                            # one-time: register GGUF
MODEL_TAG=qwen3.5:9b-q3_k_s ./install.sh          # wire it into the stack
```

`setup-gguf.sh` downloads a GGUF from `unsloth/Qwen3.5-9B-GGUF` on Hugging Face and registers it as `qwen3.5:9b-<quant lowercased>`. The Modelfile is rendered from `Modelfile.gguf.template`, which captures the upstream `RENDERER qwen3.5` / `PARSER qwen3.5` directives — ollama's built-in qwen3.5 chat/stop/tool handlers. **Without those two lines the GGUF runs against ollama's generic renderer and the model emits raw `<|im_start|>` / `<|endoftext|>` control tokens as text.** Captured here so we never need to re-pull the 6.6 GB base just to read its Modelfile.

Tested quants (M2 8 GB):

| Quant | Disk | Resident | GPU split | Decode | Notes |
|---|---|---|---|---|---|
| q4_K_M (vanilla) | 6.6 GB | 9.5 GB | 52% Metal / 48% CPU | **0.1 tok/s** | Doesn't fit, swap-thrashes |
| Q3_K_S (GGUF) | 4.3 GB | 6.3 GB | 80% Metal / 20% CPU | **~10 tok/s** | Default for 8 GB hosts |
| UD-IQ2_M (untested) | 3.65 GB | ~5 GB est. | likely 100% Metal | — | For 4 GB hosts |

`setup-gguf.sh` accepts any quant tag from the unsloth repo (Q2_K, Q3_K_M, Q4_K_S, IQ4_XS, UD-Q3_K_XL, …); swap and switch with `MODEL_TAG=...`.

## Memory budget (16 GB M4 — not negotiable for the vanilla path)

The "always loaded" requirement is in tension with 16 GB total RAM. Resolution:

- `OLLAMA_KEEP_ALIVE=-1` — never unload the model.
- `num_ctx=16384` — current setting. See "Context window tradeoffs" below for why.
- `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1` — keep memory footprint predictable.
- `OLLAMA_FLASH_ATTENTION=1` — perf gain on Apple Silicon.

Measured resident with `num_ctx=16384`: **9.07 GB unified memory**, runner reports total of 8.4 GiB (5.6 GiB Metal weights + 1.7 GiB KV + 0.5 GiB CPU weights + ~0.6 GiB compute graph). Leaves ~6.5 GB for macOS and other apps. With `num_ctx=32768`: 9.74 GB resident, ~5.8 GB free, *and* the system was sitting at 3 GB swap used under normal browser/app load.

## Context window tradeoffs

`num_ctx` directly controls KV cache size, which is the biggest non-weights memory cost. Approximate values for `qwen3.5:9b` Q4_K_M with FlashAttention on Metal:

| `num_ctx` | KV cache | Runner total | Free RAM after model | Recommendation |
|---|---|---|---|---|
| 8192 | ~0.85 GiB | ~7.55 GiB | ~7.6 GB | Below opencode-recommended floor; tool calls degrade |
| 16384 | ~1.7 GiB | ~8.4 GiB | ~6.5 GB | **Current.** Floor for reliable opencode tool calling |
| 32768 | ~2.2 GiB | ~9.1 GiB | ~5.8 GB | Better for long files / multi-step refactors. Pushes 16 GB M4 into swap |
| 65536+ | 4+ GiB | 11+ GiB | <4 GB | Don't on 16 GB. Forces severe swap |

**Decision rule for the 16 GB M4: always pick 16384 or 32768. Never go above 32768 — KV cache scales linearly with context and the math stops working.** 8192 is below opencode's documented floor for reliable tool-calling and we've never tested it; treat as risky.

When to switch to 32768: if you're doing genuinely long single-context work (reading a 5+ file refactor in one go, or processing a long document) AND you can quit other apps to free 1+ GB. Re-render the Modelfile, `ollama create`, force-evict the resident copy via `keep_alive:0`, and re-warm.

## Quantization investigation (2026-04-29)

Investigated `qwen3.5:9b-q4_K_S` (smaller than current `q4_K_M`, ~6 GB instead of 6.6 GB). **Not available on ollama's library** — verified via `ollama pull qwen3.5:9b-q4_K_S` returning `Error: pull model manifest: file does not exist`. Library only ships `q4_K_M` (smallest), `q8_0`, `bf16`, `mlx-bf16`, `nvfp4`, `mxfp8` — all the alternatives are *bigger*.

**Update (later same day, after first run on the M2 8 GB box):** the slim quants do exist on Hugging Face at `unsloth/Qwen3.5-9B-GGUF` — Q3_K_S (4.32 GB), Q3_K_M (4.67 GB), UD-IQ2_M (3.65 GB), UD-IQ2_XXS (3.19 GB), Q2_K (varies). Pulling one of those and registering it via `ollama create FROM ./file.gguf` works, **but you must add `RENDERER qwen3.5` and `PARSER qwen3.5` to the Modelfile** or the model emits `<|im_start|>` / `<|endoftext|>` as text instead of treating them as control tokens. Verified by reading `ollama show --modelfile qwen3.5:9b` from a freshly pulled vanilla copy, then deleting the vanilla. The two directives + sampling tuning are now codified in `Modelfile.gguf.template`, automated by `setup-gguf.sh`. This brings smaller quants into scope for hosts where q4_K_M doesn't fit.

## Persistence

Two LaunchAgents in `~/Library/LaunchAgents/`. **LaunchAgent, not LaunchDaemon** — assumes auto-login is enabled on the M4. If auto-login is off, ollama is unreachable until login.

### `com.user.ollama.plist` — the server

- `Program`: `/opt/homebrew/bin/ollama serve`
- `RunAtLoad`: true
- `KeepAlive`: true (restart on any exit)
- `EnvironmentVariables`: the five vars above
- `StandardOutPath` / `StandardErrorPath`: `~/Library/Logs/ollama.log`, `~/Library/Logs/ollama.err.log`

### `com.user.ollama-warm.plist` — the pre-warmer

Loads model into memory at boot so the first opencode call doesn't pay the 10–30s cold-start.

- `RunAtLoad`: true
- `KeepAlive`: false (one-shot)
- Runs a small shell script that retries `curl -d '{"model":"qwen3.5:9b-opencode","prompt":"hi","stream":false,"keep_alive":-1}' /api/generate` every 2s until ollama answers, then exits.

## Modelfile

`Modelfile` in repo root — settings live in version control, every caller (opencode, curl, future apps) gets them automatically:

```
FROM qwen3.5:9b
PARAMETER num_ctx 32768
PARAMETER temperature 0.7
PARAMETER top_k 20
PARAMETER top_p 0.8
PARAMETER min_p 0.0
PARAMETER repeat_penalty 1.0
PARAMETER presence_penalty 1.5
```

Build: `ollama create qwen3.5:9b-opencode -f Modelfile`

Sampling values are unsloth's recommended **non-thinking-mode** set for Qwen 3.5 (temp 0.7 / top_p 0.8). The official ollama library page lists the *thinking-mode* defaults (temp 1 / top_p 0.95) — using those caused our requests to emit hundreds of internal `<think>` tokens and pushed simple completions into the 30–60 s range. `num_ctx=32768` is still the opencode-docs floor for reliable tool calling. Note: there is no `PARAMETER` for thinking mode itself — it's a per-request flag (`think: false` on `/api/chat`, or `chat_template_kwargs.enable_thinking=false` on `/v1/chat/completions`).

## Tool-calling correctness

There was a real bug in **ollama < 0.19.0** where `qwen3.5:9b` printed tool calls as text instead of executing them (issue [#14745](https://github.com/ollama/ollama/issues/14745), fixed in PR [#15022](https://github.com/ollama/ollama/pull/15022), shipped in v0.19.0 on 2026-03-27). Current ollama is v0.22.x, so `brew install ollama` is safe — no pinning. Test #5 in the smoke suite explicitly verifies this fix is present in the running daemon.

## Install method

Homebrew throughout (already installed on the M4):

- `brew install ollama`
- `brew install anomalyco/tap/opencode` (the recommended opencode tap per their docs)

`install.sh` is idempotent per-section: each step checks if already done and skips.

## Repo layout

```
qwen-opencode/
├── CLAUDE.md                                # this file
├── README.md                                # user-facing docs
├── prespec.md                               # original prespec (do not modify)
├── install.sh                               # single idempotent installer
│                                            #   honours $MODEL_TAG (default qwen3.5:9b-opencode)
├── setup-gguf.sh                            # downloads + registers an Unsloth GGUF
├── test.sh                                  # opens tmux qwen-test session
├── Modelfile                                # vanilla path: FROM qwen3.5:9b
├── Modelfile.gguf.template                  # GGUF path: FROM __GGUF_PATH__ (rendered by setup-gguf.sh)
├── launchd/
│   ├── com.user.ollama.plist.template       # ollama serve on 127.0.0.1:11435
│   ├── com.user.ollama-proxy.plist.template # think:false shim on :11434
│   └── com.user.ollama-warm.plist.template  # warms __MODEL_TAG__ at boot
├── opencode/
│   └── opencode.json                        # both qwen3.5:9b-opencode and -q3_k_s listed
├── proxy/
│   └── ollama_proxy.py                      # stdlib python; see Proxy section
└── tests/
    ├── api.sh                               # 6 curl checks (uses $(hostname) for LAN test)
    └── opencode.sh                          # launches opencode w/ pre-filled prompt
```

Plists are templates with placeholders (`__USER__`, `__HOME__`, `__BREW_PREFIX__`); `install.sh` substitutes at install time.

## Test harness

`./test.sh` opens a tmux session `qwen-test` with one window, three panes:

1. **Top — logs**: `log stream --predicate 'process == "ollama"'`
2. **Middle — API smoke** (auto, prints PASS/FAIL):
   1. `GET /api/version` → 200
   2. `GET /api/tags` includes `qwen3.5:9b-opencode`
   3. `POST /api/generate` (native ollama) returns non-empty `response`
   4. `POST /v1/chat/completions` (OpenAI-compat — what opencode uses) returns non-empty content
   5. **Tool-call test**: `POST /v1/chat/completions` with a `read_file(path)` tool and prompt about `prespec.md`. Assert `choices[0].message.tool_calls[0].function.name == "read_file"` with parseable JSON args. This proves the v0.19.0 fix is live.
   6. **LAN reachability**: `curl http://m4mac.local:11434/api/version` → 200. Proves OLLAMA_HOST=0.0.0.0 works for LAN clients.
3. **Bottom — opencode** (interactive): `OPENCODE_CONFIG=./opencode/opencode.json opencode` launched with the prompt **"Read prespec.md and tell me the model name it specifies"** pre-typed. User presses Enter, observes the read tool execute end-to-end.

The opencode test is intentionally interactive — tool-call failure modes are subtle (model claims to have called a tool but didn't), and human-in-the-loop observation catches what an automated assertion misses.

## opencode config

`opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local M4)",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "qwen3.5:9b-opencode": {
          "name": "Qwen 3.5 9B (local, tool-tuned)"
        }
      }
    }
  }
}
```

LAN clients should change `baseURL` to `http://m4mac.local:11434/v1` — documented in README, not in the M4-local config.

## Implementation cadence

7 commits, push after each:

1. `scaffold: README + repo structure`
2. `add Modelfile for qwen3.5:9b-opencode`
3. `add ollama + opencode install scripts`
4. `add LaunchAgent plists for server + warmer`
5. `add opencode config for local provider`
6. `add tmux test harness`
7. `update README with usage and LAN client notes`

## Operational notes / gotchas

- **macOS firewall**: first inbound LAN connection to ollama will trigger an "Allow incoming connections?" prompt. Document in README. Don't auto-approve via `socketfilterfw` — needs sudo, not worth the friction.
- **Existing ollama**: if `Ollama.app` or `brew services start ollama` is already running, install.sh detects and `launchctl bootout`s it before installing our plists. Two competing launchd entries is the worst case to avoid.
- **Logs**: `~/Library/Logs/ollama.log` and `~/Library/Logs/ollama.err.log`. Tail these for ad-hoc debugging.
- **Uninstall**: 2-line README snippet — `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.ollama*.plist && rm` then `brew uninstall ollama opencode`.
- **Model memory after wake-from-sleep**: KEEP_ALIVE=-1 should hold across sleep, but if the model is evicted, the next request will reload (~10–30s). Acceptable.

## Things explicitly *not* in scope

- LAN client install automation (Ansible, dotfiles, scp scripts).
- Auth, TLS, reverse proxy. LAN-trust only.
- Tailscale or other VPN setup.
- Vision/multimodal use of qwen3.5 — text + tool-calling only.
- Switching to llama.cpp (Unsloth's recommendation) — current ollama works for our use case.
- Running on any host other than `m4mac.local`.

## Research that produced these decisions

Verified via WebFetch against ollama library, opencode docs, ollama GitHub issues #14745, #14601, #14493, and PR #15022 on 2026-04-28. Sampling params from the official `ollama.com/library/qwen3.5` page. Do not trust assumptions about Qwen models from general training knowledge — verify the model exists, has the size you think, and works in ollama via the library page before recommending.

## Thinking-mode investigation (2026-04-28/29)

Qwen 3.5 has thinking-on by default and there is no way to disable it via `Modelfile PARAMETER` — `PARAMETER think false` is rejected by ollama as `unknown parameter`. The toggle is per-request only.

**What works:**
- `/api/chat` body: `"think": false` — fast (~0.6 s warm for short answers).

**What does NOT work on ollama 0.22.0** (verified all four spellings against `/v1/chat/completions`, all returned 600-800 thinking tokens):
- `"chat_template_kwargs": {"enable_thinking": false}`
- `"extra_body": {"chat_template_kwargs": {"enable_thinking": false}}`
- top-level `"enable_thinking": false`
- top-level `"think": false`

Qwen 3's `/think` and `/nothink` system-prompt directives are silently ignored on Qwen 3.5.

**Sampling params** are now Unsloth's recommended *non-thinking-mode* set (`temp 0.7, top_p 0.8, min_p 0`) instead of the ollama-library *thinking-mode* defaults (`temp 1, top_p 0.95`). Reduces verbosity even when thinking is on.

## Fake-streaming proxy (`proxy/ollama_proxy.py`)

stdlib python proxy that fronts ollama:
- `POST /v1/chat/completions` (streaming and non-streaming): translates to `/api/chat` with `think:false`. For streaming, sends `: keepalive` SSE comments every 1 s while ollama generates, then dumps the full response as a single `delta.content` chunk + finish + `[DONE]`.
- `POST /api/chat` and `/api/generate`: injects `"think": false` if not specified.
- Tool-call format conversion in **both directions** (ollama uses parsed-object `arguments`; OpenAI clients send JSON-string `arguments`). Without the inbound translation, opencode trips a 400 on the second turn of any tool call.
- All other paths: transparent passthrough.

Config:
- listens `0.0.0.0:11434`
- forwards to `127.0.0.1:11435` (where ollama needs to be moved)
- env vars: `OLLAMA_PROXY_LISTEN_HOST/PORT`, `OLLAMA_PROXY_UPSTREAM_HOST/PORT`, `OLLAMA_PROXY_HEARTBEAT_S` (default 1), `OLLAMA_PROXY_VERBOSE=1`
- python 3.9+ stdlib only (no deps). **Avoid f-strings with backslashed quotes** (3.9 syntax error).

## Benchmark data (2026-04-28, m4mac warm, 32K ctx)

Curl matrix (3 prompts × 3 trials × 3 paths):

| Prompt | /v1 PROXY (nonstream) | /v1 STREAM PROXY | /api/chat DIRECT (think:false) |
|---|---|---|---|
| 3-word | 730 ms / 5 tok | 675 ms / 4 tok | 708 ms / 5 tok |
| 2-sentence | 4438 ms / 55 tok | 4638 ms / 58 tok | 4456 ms / 55 tok |
| Toolish (~450 tok) | 34.8 s | 27.4 s | 37.6 s |

**Conclusion: proxy adds zero measurable overhead.** All three paths are within sampling noise. Sustained decode is **~13 tok/s** regardless of path or prompt size.

opencode TUI matrix (3 prompts × 3 trials, through proxy, in tmux):

| Prompt | Wall (mean) | Range | opencode self-reports |
|---|---|---|---|
| 3-word | 88.3 s | 87.95–89.05 s | 1m 27–28s |
| 2-sentence | 95.9 s | 95.14–96.27 s | 1m 34–35s |
| File read tool call | 111.2 s | 109.53–112.54 s | 1m 49–51s |

**Variance ~1% across trials** — extremely consistent.

Pre-proxy (thinking on, baseline) for the 3-word prompt: 252 s. Post-proxy: 88 s. **2.7× speedup for the same UX.**

## Why opencode is still slow even with the proxy

The proxy's overhead is zero, but opencode's behavior caps the achievable speed:

1. **opencode sends ~14k tokens of system prompt + tool defs** every turn. At ~13 tok/s decode after a long prefill, every roundtrip is 60–90 s minimum even with thinking off.
2. **opencode duplicates every `/v1/chat/completions` request** (visible in proxy logs as pairs with identical timestamps). Likely an AI-SDK preflight + main pattern. Doubles inference cost. Not fixable in a passthrough proxy without dedup logic that risks losing tool-call state.
3. Tool-using turns make 3+ ollama roundtrips per user prompt, so they compound the per-turn cost.

**Bottom line: this hardware is the ceiling, not the proxy.** Sub-2-minute responses for opencode chat, 2–5 minutes for tool-using turns, with rock-solid consistency.

## Proxy status (as of 2026-04-29)

- ✅ Code committed at `proxy/ollama_proxy.py`
- ✅ Verified against api.sh (6/6 PASS through proxy)
- ✅ Verified end-to-end with opencode TUI (real tool call executed)
- ❌ **NOT yet wired as a LaunchAgent.** ollama is currently bound back to `0.0.0.0:11434` (bypassing the proxy). The proxy was tested in foreground only.
- ❌ install.sh has not been updated to provision the proxy.
- ❌ README has no proxy section.

## Next steps for the proxy

If we decide to ship it permanently:

1. Update `launchd/com.user.ollama.plist.template` — `OLLAMA_HOST=127.0.0.1:11435` (LAN reach moves to the proxy).
2. New `launchd/com.user.ollama-proxy.plist.template` — runs `python3 proxy/ollama_proxy.py`, KeepAlive=true, binds `:11434`.
3. Update install.sh to install + bootstrap the proxy plist after the server (and before the warmer, so the warmer's `:11434` request goes through the proxy and exercises the translation).
4. Update warmer's curl to either keep using `/api/generate` (which the proxy also injects `think:false` on) or call the proxy at `:11434` — either works.
5. Add a "Proxy" section to README + CLAUDE.md describing what it does and the env-var knobs.
6. Add proxy-specific tests to api.sh (e.g., assert that `/v1/chat/completions` returns within 30 s for a short prompt — would fail without the proxy).

If we decide NOT to ship it: delete `proxy/` and remove this section.

## Open issues / known limitations

- **opencode duplicate requests**: documented above. ~2× cost, not fixable in proxy.
- **opencode `--format json` buffers until exit**: do not use for headless benchmarking; the file stays 0 bytes for many minutes. Use the tmux + send-keys + capture-pane pattern from `/tmp/oc_tmux_bench.sh` (lost — recreate if needed).
- **macOS `log stream` does not show ollama output** because the LaunchAgent uses `StandardOutPath`/`StandardErrorPath` (file redirection, not `os_log`). `test.sh` uses `tail -F` on the log files instead.
- **`launchctl bootstrap` returns Bootstrap: 5 EIO** if the agent is already loaded. install.sh now only bootstraps when the plist content actually changed; otherwise it just verifies the agent is loaded.
- **Proxy mangles `/api/pull` responses**: confirmed 2026-04-29 with `ollama pull qwen3.5:9b-q4_K_S` failing through the proxy with `malformed HTTP response "0"`. The pull endpoint streams NDJSON (newline-delimited JSON), not SSE — our chunked-passthrough breaks the framing somehow. **Workaround: pull through the upstream directly with `OLLAMA_HOST=127.0.0.1:11435 ollama pull <tag>`.** Fix would be either (a) detect `/api/pull` and `/api/push` and stream raw without re-chunking, or (b) buffer the entire response. (a) is correct, (b) defeats progress reporting.
