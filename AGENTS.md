# qwen-opencode agent rules

Project-level rules for any agent operating in this repo via opencode.

## Tool-use discipline

When the user asks you to run a shell command or asks a question whose answer
requires running a command, you **must invoke the `bash` tool**. Do not:

- echo the command back as a text reply ("pwd" is not an answer)
- predict or fabricate the command's output (no fake commit hashes, no made-up
  paths, no guessed directory listings)
- describe what the command would do without actually running it

The `bash` tool exists so you can read real output. Use it.

### bash tool — examples

User: *"Use the bash tool to run `pwd` and tell me the current working directory."*

What you do:
1. Invoke the `bash` tool with `command: "pwd"`.
2. Read the tool's output (e.g. `/Users/marcelo/REPOS/qwen-opencode`).
3. Reply with that directory.

---

User: *"What's the most recent commit message?"*

What you do:
1. Invoke the `bash` tool with `command: "git log --oneline -1"`.
2. Read the output (e.g. `ec1dbe3 add GGUF install path…`).
3. Reply with the message portion.

---

User: *"What files are in the current directory?"*

What you do:
1. Invoke the `bash` tool with `command: "ls"`.
2. Read the output.
3. Summarise the listing.

### Read-only vs destructive commands

The above examples are read-only and always safe. For destructive commands
(`rm`, `git push --force`, `mv` overwriting existing files, `kill`, dropping
database tables, etc.) confirm with the user first. When in doubt, ask.

## File-read tool

The `read` tool reads a file from disk. Use it when the user asks about the
contents of a specific file. Do not paraphrase what the file might contain
based on its name — actually read it.

## opencode config notes (for humans reading this file)

opencode auto-loads this `AGENTS.md` from the repo root and prepends it to its
system prompt. Lookup order: local `AGENTS.md` → `~/.config/opencode/AGENTS.md`
→ `CLAUDE.md` (silent fallback). The first match wins.

**Why this file matters for memory.** Without `AGENTS.md`, opencode falls back
to `CLAUDE.md`, which adds ~6 k tokens of design notes to every turn. Measured
2026-04-29: input dropped from 17.1 k → 11.2 k tokens just by introducing this
file. On a local model running ~8–10 tok/s, that's ~40 s of prefill saved
per request.

**Provider config.** opencode talks to the local stack via
`opencode/opencode.json` (project-local) or `~/.config/opencode/opencode.json`
(global, for LAN clients). Both point at the proxy on `:11434/v1`. The
registered model tags are `qwen3.5:9b-opencode` (vanilla q4_K_M, 16 GB hosts)
and `qwen3.5:9b-q3_k_s` (GGUF Q3_K_S, 8 GB hosts).

**Context window.** Both Modelfiles use `num_ctx=32768`. Don't drop to 16384 —
opencode's prompt + tool defs (~11–17 k tokens) saturates the smaller cap and
the model emits 0–2 output tokens per turn. 32768 is the floor for opencode
tool-calling on this stack as of 2026-04-29.

**Available tools.** opencode exposes `bash` (shell command execution) and
`read` (file read) among others. The examples above use those names verbatim;
if you change clients, the names change too.
