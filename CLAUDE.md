# qwen-opencode

Always-on local ollama server hosting `qwen3.5:9b` for opencode and other LAN clients.

## Topology

- **Host**: `m4mac.local` — Apple M4, 16 GB unified memory, Metal 4. This is the *only* host. LAN clients are out of scope for install scripts.
- **Model**: pulled as `qwen3.5:9b` from the ollama library (6.6 GB, 256K-capable), then re-tagged as `qwen3.5:9b-opencode` after baking in tuned params via Modelfile.
- **Server binding**: `OLLAMA_HOST=0.0.0.0:11434`. No auth — trusted home LAN. Reachable from other LAN devices via Bonjour at `m4mac.local:11434`.
- **opencode**: installed on the M4 only, used for the tmux smoke test. Other LAN clients install opencode manually later.

## Memory budget (16 GB M4 — not negotiable)

The "always loaded" requirement is in tension with 16 GB total RAM. Resolution:

- `OLLAMA_KEEP_ALIVE=-1` — never unload the model.
- `num_ctx=32768` — capped at 32K, **not** the model's max 256K. Larger contexts blow up KV cache and trigger swap.
- `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1` — keep memory footprint predictable.
- `OLLAMA_FLASH_ATTENTION=1` — perf gain on Apple Silicon.

Total resident with model loaded: ~7–9 GB. Leaves 7+ GB for macOS and the user's other apps.

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
PARAMETER temperature 1
PARAMETER top_k 20
PARAMETER top_p 0.95
PARAMETER repeat_penalty 1.0
PARAMETER presence_penalty 1.5
```

Build: `ollama create qwen3.5:9b-opencode -f Modelfile`

Sampling values are from the official ollama qwen3.5 model page. `num_ctx=32768` is the opencode-docs-recommended floor for reliable tool calling.

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
├── CLAUDE.md                           # this file
├── README.md                           # user-facing docs
├── prespec.md                          # original prespec (do not modify)
├── install.sh                          # single idempotent installer
├── test.sh                             # opens tmux qwen-test session
├── Modelfile
├── launchd/
│   ├── com.user.ollama.plist.template
│   └── com.user.ollama-warm.plist.template
├── opencode/
│   └── opencode.json                   # provider=ollama, model=qwen3.5:9b-opencode
└── tests/
    ├── api.sh                          # 6 curl checks
    └── opencode.sh                     # launches opencode w/ pre-filled prompt
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
