# Qwen 3.5 9b and opencode

Create an always on always persisting ollama server with qwen3.5 9b model.

The server should be 100% compatible with opencode and allow my local network computers 
to call the model and use it on opencode, or in other applications.

There are a few important caveats on setting it. Check reddit forums for insights.

You should test the implementation using tmux - first to call the API to make sure it works; 
and second - test in tmux with opencode to make sure opencode properly responds to qwen, and 
also uses tool calls (a problematic thing with qwen and that the community sorted out).

Ollama knowingly stops the server to save memory. I want you to find a way to persist it no matter what.

Commit and push as you go. create shell scripts here to install ollama if not there, opencode if not there, 
download qwen 3.5 9b if not there and install/start the persistent server if not there.

Server should restart if computer is rebooted.
