# dreamux-signals MCP

Read/write bridge between external Claude Code agents and Dreamux's
signal ledger (`~/Library/Application Support/com.dreamux.Dreamux/signals.db`).
Read tools query SQLite directly (read-only, WAL-safe); `signals_emit`
and `signals_subscribe` talk to the running app over
`/tmp/dreamux-emit-com.dreamux.Dreamux.sock`.

Dreamux auto-installs this into a project's `.mcp.json` at agent-session
start (see `MCPInstaller.swift`). Manual wiring:

    claude mcp add dreamux-signals ~/.asdf/installs/bun/<ver>/bin/bun run <this repo>/mcp/dreamux-signals-mcp.ts

Env overrides: DREAMUX_SIGNALS_DB, DREAMUX_PROJECT_DIR,
DREAMUX_SIGNALS_ALL_PROJECTS=1, DREAMUX_SIGNALS_EMIT_SOCKET.
Requires bun (the installer probes ~/.bun, Homebrew, and asdf installs
for an absolute path — MCP servers spawn with a stripped PATH).
