#!/usr/bin/env bash
# Open a tmux session "qwen-test" with three panes:
#   top    — ollama log stream
#   middle — api smoke tests (auto, prints PASS/FAIL)
#   bottom — opencode (interactive, prompt pre-typed)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="qwen-test"
PROMPT='Read prespec.md and tell me the model name it specifies'

command -v tmux >/dev/null || { echo "tmux required: brew install tmux" >&2; exit 1; }
command -v opencode >/dev/null || { echo "opencode required: run ./install.sh first" >&2; exit 1; }

# Kill prior session so re-running is safe.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Window: start with log streamer in pane 0.
# Top pane: tail the ollama log files. Note: macOS `log stream` doesn't show
# ollama output because the LaunchAgent redirects stdout/stderr to files via
# StandardOutPath, not via os_log.
tmux new-session -d -s "$SESSION" -x 220 -y 60 \
    "tail -F $HOME/Library/Logs/ollama.log $HOME/Library/Logs/ollama.err.log 2>/dev/null"

# Split horizontally below pane 0 — pane 1 (middle) runs the API tests.
tmux split-window -v -t "$SESSION:0.0" \
    "bash '$REPO_ROOT/tests/api.sh'; echo; echo 'press q in this pane to exit, or Ctrl-b d to detach.'; read -r"

# Split pane 1 again — pane 2 (bottom) hosts opencode.
tmux split-window -v -t "$SESSION:0.1" \
    "bash '$REPO_ROOT/tests/opencode.sh'"

# Even out the three panes vertically.
tmux select-layout -t "$SESSION:0" even-vertical

# Give opencode a moment to render its prompt, then pre-type the test
# prompt into the bottom pane. Don't send Enter — leave that to the user.
( sleep 6 && tmux send-keys -t "$SESSION:0.2" "$PROMPT" ) &

tmux select-pane -t "$SESSION:0.2"
tmux attach -t "$SESSION"
