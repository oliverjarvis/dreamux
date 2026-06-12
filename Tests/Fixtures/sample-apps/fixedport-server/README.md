# fixedport-server

Clayspace test fixture. A python3 stdlib HTTP server that binds a
HARDCODED port (4700), so only one instance can run at a time — the
exact situation the Run pane's "Isolate with Claude" flow exists to
fix.

- `GET /` returns `{"app": "fixedport-server", "cwd": "<cwd>", "port": <port>}`.
- Prints `listening on <port>` to stdout on startup.
- Exits cleanly on SIGTERM.

## Marker-line contract

`server.py` contains exactly this line:

    PORT = 4700  # CLAYSPACE-FIXTURE-PORT

The fake `claude` shim (Tests/Fixtures/bin/claude) rewrites it during
the isolate flow to:

    PORT = int(os.environ.get("FIXEDPORT_SERVER_PORT", "4700"))  # CLAYSPACE-FIXTURE-PORT

and appends `port_env = "FIXEDPORT_SERVER_PORT"` to the matching
`[[runners]]` entry in `.clayspace/run.toml`. Tests assert on these
exact strings — change them in both places or not at all.

`clayspace-runner.snippet.toml` is the `[[runners]]` block the shim
concatenates into `.clayspace/run.toml` during detect; `{{CWD}}` is
substituted with `repos/<repo>/<branch>`. Note it has no `port_env`
line — that is the point of this fixture.

Run: `python3 server.py`
