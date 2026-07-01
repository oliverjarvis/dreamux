# portenv-server

Dreamux test fixture. A python3 stdlib HTTP server whose port comes
from the `PORTENV_SERVER_PORT` environment variable (default 4600), so
multiple instances can run concurrently — one per worktree.

- `GET /` returns `{"app": "portenv-server", "cwd": "<cwd>", "port": <port>}`.
- Prints `listening on <port>` to stdout on startup.
- Exits cleanly on SIGTERM.

`dreamux-runner.snippet.toml` is the `[[runners]]` block the fake
`claude` shim (Tests/Fixtures/bin/claude) concatenates into
`.dreamux/run.toml` during detect; `{{CWD}}` is substituted with
`repos/<repo>/<branch>`.

Run: `python3 server.py`
