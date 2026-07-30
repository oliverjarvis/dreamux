<p align="center">
  <img src="assets/capsule.png" alt="Dreamux — design. dream. build." />
</p>

<h1 align="center">Dreamux</h1>

<p align="center"><em>design. dream. build.</em></p>

## Install

Dreamux is a native macOS app you build from source — there's no App Store
listing or notarized download yet (both are on the roadmap). One command
builds a release `.app`, installs it, and launches it:

**Requirements:** macOS 14+ and a Swift toolchain (Xcode, or the Command Line
Tools via `xcode-select --install`).

```sh
./Scripts/install-app.sh
```

It installs to `/Applications` (admin users need no sudo), or `~/Applications`
when that isn't writable — an existing install always wins, so re-runs update
in place. Flags: `--dest DIR` to pick the folder, `--no-relaunch` to skip
launching, `debug` for a debug build.

Launch it from Spotlight (⌘-Space → "Dreamux"), Launchpad, or Finder — and
drag it to the Dock to keep it handy. Because you built it yourself the app
isn't quarantined, so Gatekeeper opens it without complaint; if a later build
ever prompts, right-click it → **Open** once.

**Updating** (there's no auto-updater yet): `git pull` on `main`, then re-run
`./Scripts/install-app.sh`. This works from a terminal *inside* Dreamux: when
the installed app is running, the script hands the quit → swap → relaunch tail
to a detached helper (log: `$TMPDIR/dreamux-install-app.log`), gracefully
quits the app, swaps the bundle, and relaunches it on the new build. Check
what's installed with
`plutil -p /Applications/Dreamux.app/Contents/Info.plist | grep Dreamux` —
every build is stamped with its commit, build date, and source checkout.

> **Side-by-side dev builds.** `./Scripts/dev-dogfood.sh` builds and launches a
> *tagged* Dreamux (`./Scripts/make-app.sh release <tag>`) with its own bundle
> id — an isolated data dir, emit socket, and window state — so it runs next to
> your everyday app without collisions. Handy for developing Dreamux inside
> Dreamux.

## CLI

The Dreamux binary doubles as a small command-line tool for controlling the
app programmatically — e.g. creating projects from a script. A recognized
subcommand runs headless and exits; any other invocation launches the GUI as
usual, so it's the same one binary.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/oliverjarvis/dreamux/main/install.sh | bash
```

This links the `dreamux` command onto your PATH (`/usr/local/bin` or
`~/.local/bin`). It requires Dreamux.app to be installed first — see
[Install](#install) above. Prefer to wire the command up by hand:

```sh
ln -sf "/Applications/Dreamux.app/Contents/MacOS/Dreamux" /usr/local/bin/dreamux
# …or, without touching PATH, just alias it:
alias dreamux="/Applications/Dreamux.app/Contents/MacOS/Dreamux"
```

> Because the CLI is currently the app's own binary, "installing" just wires
> up the command from your installed app — the same way VS Code installs
> `code`. A standalone, `curl`-downloads-a-binary install will come if/when the
> CLI ships as its own release.

### Commands

```sh
dreamux clone <url> [--name NAME]   # clone a git URL into a new project
dreamux add   <dir> [--name NAME]   # add a local directory as a new project
dreamux list                        # list existing projects
dreamux help
```

- **clone** — clones the repo into a new project at
  `<projects-root>/<NAME>/repos/<repo>` (a bare repo + `main` worktree — the
  same layout the app's "Add repository" produces). `NAME` defaults to the
  repo name.
- **add** — imports a local directory the same way (its history is cloned; the
  original directory is left in place). A directory that isn't a git repo yet
  is `git init`'d with an initial commit first, since Dreamux projects are
  git-backed. `NAME` defaults to the directory name.
- Projects are folders under the **projects root** — `~/Documents/Dreamux` by
  default, overridable with the `DREAMUX_PROJECTS_ROOT` environment variable. A
  running app discovers a newly-created project the next time one of its
  windows (re)opens.

```sh
dreamux clone https://github.com/owner/repo.git --name my-project
dreamux add ~/code/existing-thing
dreamux list
```

## Applets & App Studio

Instead of context-switching across a dozen SaaS dashboards, commission small
bespoke dev tools — *applets* — right inside Dreamux. Describe what you need in
a sentence and a Claude agent builds it; the applet renders in the app, lives
in the sidebar's **APPS** section, and opens in the project's main pane like a
workspace.

An applet is a self-contained folder (`manifest.json` + `index.html` + assets)
rendered in a locked-down web view. It's **buildless** — a vendored
Preact + htm gives a React-like feel with no npm, bundler, or dev server, so
applets are cheap to build, instant to run, and shareable by copying the
folder. Examples: a kanban board, a component kitchen-sink, an Expo-deployments
tracker, a deploy dashboard.

**Where they live**

- **App Studio** (a window off the projects rail) is a global library of
  canonical applets, stored under `~/Documents/Dreamux/Apps/` (override with
  `DREAMUX_APPS_ROOT`).
- A project **adopts** an applet — a project-local copy under
  `<project>/apps/<slug>/` that records its lineage and can be tailored
  freely — or creates a **local-born** one in place (publishable to App Studio
  later). Per-applet data lives at `<project>/.dreamux/appdata/<slug>/`.

**The `window.dreamux` bridge**

Applets reach real dev-machine power through a small, capability-gated native
API — each method requires the matching entry in the manifest's
`requiresCapabilities`, or the call is rejected:

| Capability | API |
|---|---|
| — (always) | `dreamux.context()` → project name / root / data dir |
| `kv` | `dreamux.kv.get/set/delete/list` — the applet's key-value store |
| `fs` | `dreamux.fs.read/write/list/delete` — scoped to the applet's own files |
| `http` | `dreamux.http.fetch(url, opts)` → `{status, headers, text}` (CORS-free; text responses) |
| `shell` | `dreamux.shell.exec(cmd, {cwd, timeout})` → `{stdout, stderr, code}` (timeout in seconds, default 60) |
| `notify` | `dreamux.notify(title, body)` |

Because `shell` and `http` compose with any CLI or API on your machine, most
applets need no changes to Dreamux itself. Capabilities that require an OS
permission (screen capture, input control) are added to the bridge as
deliberate Dreamux releases — see `docs/superpowers/specs/` for the design and
the deferred roadmap (marketplace, adoption sync, entitled capabilities).

**Connections — authenticated access**

To show *your* data (private-repo PRs, Expo builds, …), an applet authenticates
through a **Connection**: a named credential kept in the macOS **Keychain**,
with an auth kind and an enforced **host allowlist**. The secret never enters
the applet's JS — it's attached natively.

- Manage them in **Settings → Connections**: paste a token, or **Import from
  `gh` / `eas`** to reuse a CLI login you already have.
- An applet *declares* what it needs in its manifest (`requiresConnections`,
  carrying no secret), and you **bind** each slot to a Connection from a banner
  in the applet — so shared applets are safe and each person wires up their own.
- At call time the credential is attached natively:
  `dreamux.http.fetch(url, { connection: "github" })` — sent **only over
  `https`**, **only to an allowlisted host** (redirects included), token never
  reaching the web view — or `dreamux.shell.exec(cmd, { connection })` to inject
  it as env into a single process.

OAuth flows are on the roadmap; today's Connections cover token/PAT APIs and
CLI-backed logins.
