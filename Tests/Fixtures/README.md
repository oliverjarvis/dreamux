# Test fixtures

Git-tracked data for the Clayspace test suite. Nothing in here is a
SwiftPM resource — tests locate this directory via `#filePath` (see
`RepoFixtures` in Tests/ClayspaceTests/Support/TestSandbox.swift) and
copy what they need into a per-test sandbox. There are intentionally no
nested `.git` directories; tests `git init` their copies themselves.

## bin/claude — the fake claude shim

An executable python3 script that impersonates the real `claude` CLI
for e2e runs (put `Tests/Fixtures/bin` first on `PATH`). It recognizes
the three prompts the Run pane sends (RunSetupView.swift) and performs
the minimal deterministic edits the real agent would:

- **detect** (prompt contains `Inspect every repo`): for each repo
  under `./repos/*` it finds the default branch folder (first
  non-hidden dir that isn't `.bare`), reads that folder's
  `clayspace-runner.snippet.toml`, substitutes `{{CWD}}` with
  `repos/<repo>/<branch>`, concatenates everything into
  `./.clayspace/run.toml`, and prints `run.toml ready`.
- **isolate** (prompt contains `the runner named "<name>" currently
  binds a fixed port`): rewrites the marker line (below) in every
  branch worktree under `repos/<name>/`, appends
  `port_env = "<NAME>_PORT"` to the matching `[[runners]]` entry in
  `./.clayspace/run.toml`, and prints `isolated <name>`.
- **diagnose** (prompt contains `Figure out why and fix it`): prints
  `diagnosed <runner>` and makes no edits.

Any other prompt exits 1 with `fake-claude: unrecognized prompt` on
stderr, so a drifted app prompt breaks tests loudly. The shim assumes
its cwd is the project root, which is where the Run pane's terminal
session starts.

## sample-apps/

Plain directories tests commit into sandboxed Clayspace repos (via
`GitFixtures.makeBareLayoutRepo`). Both are python3-stdlib HTTP servers
that print `listening on <port>` on startup, answer `GET /` with
`{"app": ..., "cwd": ..., "port": ...}`, and exit cleanly on SIGTERM.
Each carries a `clayspace-runner.snippet.toml` — the `[[runners]]`
block the fake claude's detect flow stitches into `run.toml` (with
`{{CWD}}` substituted). Both snippets start the server by absolute
path (`python3 "$PWD/server.py"`) and stop it with a pkill pattern
anchored on that same path: the stop command really executes during
e2e runs, and an unanchored `pkill -f 'python3 server.py'` would kill
matching processes anywhere on the host.

- **portenv-server/** binds `int(os.environ.get("PORTENV_SERVER_PORT",
  "4600"))`; its snippet includes `port_env`, so the app can run one
  instance per worktree out of the box.
- **fixedport-server/** hardcodes port 4700; its snippet has NO
  `port_env`, making it the target of the isolate flow.

## The marker-line contract

`fixedport-server/server.py` contains exactly:

    PORT = 4700  # CLAYSPACE-FIXTURE-PORT

The fake claude's isolate flow rewrites exactly that line to:

    PORT = int(os.environ.get("FIXEDPORT_SERVER_PORT", "4700"))  # CLAYSPACE-FIXTURE-PORT

(preserving the original port as the default and ensuring `import os`
exists). Tests assert on these strings — keep the fixture, the shim,
and this document in sync.

Ports: fixtures use the 46xx–47xx range only, to stay clear of anything
developers commonly run.
