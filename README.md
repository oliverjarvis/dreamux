<p align="center">
  <img src="assets/capsule.png" alt="Dreamux — design. dream. build." />
</p>

<h1 align="center">Dreamux</h1>

<p align="center"><em>design. dream. build.</em></p>

## CLI

The Dreamux binary doubles as a small command-line tool for controlling the
app programmatically — e.g. creating projects from a script. A recognized
subcommand runs headless and exits; any other invocation launches the GUI as
usual, so it's the same one binary.

The binary lives inside the app bundle; alias it for convenience:

```sh
alias dreamux="/Applications/Dreamux.app/Contents/MacOS/Dreamux"
# …or wherever your build is, e.g. ./Dreamux.app/Contents/MacOS/Dreamux
```

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
