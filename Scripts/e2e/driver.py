#!/usr/bin/env python3
"""Out-of-process e2e driver for Dreamux.

Launched by Scripts/e2e/run-e2e.sh after it has built the app bundle,
created a per-run sandbox, and seeded local git repos from the fixture
sample apps. This script launches the app binary directly (so env vars
pass through), speaks the newline-delimited-JSON protocol documented in
Scripts/e2e/PROTOCOL.md over the unix socket, and runs the scenarios in
order, hard-asserting on disk state, app state, and live HTTP responses
from the fixture servers. Screenshots land in $ARTIFACTS.

python3 stdlib only — no third-party deps.

Environment contract (set by run-e2e.sh):
  E2E_APP_BINARY       Dreamux.app/Contents/MacOS/Dreamux (absolute)
  E2E_SANDBOX          per-run sandbox root (mktemp -d)
  E2E_SOCKET           short /tmp path for the app's unix socket
  E2E_SEED_DIR         dir containing the seeded portenv-server /
                       fixedport-server git repos
  E2E_PROJECT_NAME     project folder name under the projects root
  E2E_EMIT_SOCKET      bundle-id-derived path for the always-on hook
                       signal socket (SignalEmitSocketServer), used by
                       scenario_flows to emit agent/notification
                       signals the same way a real claude hook does
  ARTIFACTS            screenshot/log output dir (wiped by run-e2e.sh)
  DREAMUX_CLAUDE_BIN the fake claude shim (forwarded to the app)
  DREAMUX_GH_BIN     the fake gh shim (forwarded to the app)
  DREAMUX_CLAUDE_HOME synthetic ~/.claude root (forwarded to the app);
                       scenario_flows writes session-registry entries
                       under its sessions/ dir, and a synthetic
                       transcript + subagent meta under projects/<slug>/
                       for the zoomFlow lazy-replay step

Exit status: 0 only when every scenario passed.
"""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# Environment

APP_BINARY = os.environ["E2E_APP_BINARY"]
SANDBOX = os.environ["E2E_SANDBOX"]
SOCKET_PATH = os.environ["E2E_SOCKET"]
SEED_DIR = os.environ["E2E_SEED_DIR"]
PROJECT_NAME = os.environ.get("E2E_PROJECT_NAME", "demo-project")
ARTIFACTS = os.environ["ARTIFACTS"]
CLAUDE_BIN = os.environ["DREAMUX_CLAUDE_BIN"]
GH_BIN = os.environ["DREAMUX_GH_BIN"]
CLAUDE_HOME = os.environ["DREAMUX_CLAUDE_HOME"]
EMIT_SOCKET_PATH = os.environ["E2E_EMIT_SOCKET"]

PROJECTS_ROOT = os.path.join(SANDBOX, "projects")
STATE_DIR = os.path.join(SANDBOX, "state")
PROJECT_DIR = os.path.join(PROJECTS_ROOT, PROJECT_NAME)

GIT_IDENTITY = [
    "-c", "user.name=Dreamux E2E",
    "-c", "user.email=e2e@dreamux.local",
]


class E2EFailure(Exception):
    """A scenario assertion failed. Carries a human-readable message."""


def require(condition, msg):
    if not condition:
        raise E2EFailure(msg)


def log(msg):
    print(f"  [driver] {msg}", flush=True)


def git(*args, cwd):
    """Run git with a deterministic identity; raise on non-zero exit."""
    result = subprocess.run(
        ["git", *GIT_IDENTITY, *args],
        cwd=cwd, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise E2EFailure(
            f"git {' '.join(args)} in {cwd} failed: {result.stderr.strip()}"
        )
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Driver

class Driver:
    """Owns the app process, the socket connection, and screenshots."""

    def __init__(self):
        self.app = None
        self.sock = None
        self.sockfile = None
        self.shot_counter = 0
        self.launch_counter = 0

    # -- app lifecycle ------------------------------------------------------

    def launch_app(self, extra_env=None):
        """Launch the binary inside Dreamux.app directly so env vars
        pass through, then wait for the automation socket to accept."""
        self.launch_counter += 1
        env = os.environ.copy()
        env.update({
            "DREAMUX_E2E_SOCKET": SOCKET_PATH,
            "DREAMUX_E2E_AUTOOPEN": PROJECT_NAME,
            "DREAMUX_PROJECTS_ROOT": PROJECTS_ROOT,
            "DREAMUX_STATE_DIR": STATE_DIR,
            "DREAMUX_CLAUDE_BIN": CLAUDE_BIN,
            "DREAMUX_GH_BIN": GH_BIN,
            "DREAMUX_CLAUDE_HOME": CLAUDE_HOME,
        })
        if extra_env:
            env.update(extra_env)

        # Drop any stale socket file from a previous launch before the
        # app spawns. A leftover path can otherwise accept our connect
        # via a listener fd that leaked into now-orphaned children of
        # the previous app instance (PTY shells), where nothing will
        # ever reply.
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass

        log_path = os.path.join(ARTIFACTS, f"app-{self.launch_counter}.log")
        self.app_log = open(log_path, "ab")
        # -ApplePersistenceIgnoreState YES: without it, AppKit restores
        # whatever windows the user's last real Dreamux session left
        # behind (keyed by bundle id) — a stale project window from
        # outside the sandbox would hijack the run and the launch gate
        # (whose .onAppear performs DREAMUX_E2E_AUTOOPEN) never
        # resolves into the demo project.
        self.app = subprocess.Popen(
            [APP_BINARY, "-ApplePersistenceIgnoreState", "YES"],
            env=env,
            cwd=SANDBOX,
            stdout=self.app_log,
            stderr=self.app_log,
        )
        log(f"launched app pid={self.app.pid} (log: {log_path})")
        self.connect(timeout=20.0)
        self.cmd("ping")

    def connect(self, timeout=20.0):
        """Retry-connect to the unix socket; the server binds very early
        but the protocol tells drivers to retry for a couple seconds."""
        deadline = time.monotonic() + timeout
        last_err = None
        while time.monotonic() < deadline:
            if self.app and self.app.poll() is not None:
                raise E2EFailure(
                    f"app exited (code {self.app.returncode}) before the "
                    f"socket accepted — see app log in {ARTIFACTS}"
                )
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(SOCKET_PATH)
                s.settimeout(120.0)  # per-command ceiling; commands block
                self.sock = s
                self.sockfile = s.makefile("rwb")
                return
            except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
                last_err = e
                time.sleep(0.2)
        raise E2EFailure(f"socket {SOCKET_PATH} never accepted: {last_err}")

    def close_socket(self):
        for closer in (self.sockfile, self.sock):
            try:
                if closer:
                    closer.close()
            except OSError:
                pass
        self.sockfile = None
        self.sock = None

    def wait_for_exit(self, timeout=8.0):
        """Wait for the app process to die (quit has a ~2s forced-exit
        backstop server-side)."""
        try:
            self.app.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise E2EFailure(f"app did not exit within {timeout}s of quit")
        finally:
            self.close_socket()
        log(f"app exited with code {self.app.returncode}")

    def terminate(self):
        """Best-effort teardown of the app process: polite quit first,
        SIGTERM/SIGKILL after."""
        if self.app is None:
            return
        if self.app.poll() is None:
            try:
                if self.sockfile:
                    self.cmd("quit")
            except Exception:
                pass
            try:
                self.app.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                self.app.terminate()
                try:
                    self.app.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    self.app.kill()
        self.close_socket()

    # -- protocol -----------------------------------------------------------

    def cmd(self, command, /, expect_ok=True, **kwargs):
        """Send one command, read one reply. Raises on ok:false unless
        the scenario explicitly expects failure (expect_ok=False). The
        command name is positional-only so protocol parameters like
        `name=` pass through **kwargs without colliding."""
        payload = {"cmd": command}
        payload.update(kwargs)
        line = json.dumps(payload).encode("utf-8") + b"\n"
        self.sockfile.write(line)
        self.sockfile.flush()
        reply = self.sockfile.readline()
        if not reply:
            raise E2EFailure(f"connection dropped while awaiting reply to {command}")
        response = json.loads(reply.decode("utf-8"))
        if expect_ok and not response.get("ok"):
            raise E2EFailure(f"{command} failed: {response.get('error', response)}")
        return response

    def state(self):
        return self.cmd("state")

    # -- helpers ------------------------------------------------------------

    def wait_until(self, fn, timeout, msg, interval=0.5):
        """Poll fn until it returns truthy; raise E2EFailure on timeout.
        Returns fn's final (truthy) value."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = fn()
            if value:
                return value
            time.sleep(interval)
        raise E2EFailure(f"timed out after {timeout}s waiting for: {msg}")

    def screenshot(self, label):
        """In-process window render via the automation server. Saves to
        $ARTIFACTS/<NN>-<label>.png and asserts the file is non-empty."""
        self.shot_counter += 1
        path = os.path.join(ARTIFACTS, f"{self.shot_counter:02d}-{label}.png")
        self.cmd("screenshot", path=path)
        require(
            os.path.isfile(path) and os.path.getsize(path) > 0,
            f"screenshot {path} missing or empty",
        )
        log(f"screenshot -> {os.path.basename(path)}")
        return path

    def http_get_json(self, port, timeout=2.0):
        """GET / from a fixture server; returns its JSON identity blob
        {"app","cwd","port"}. Raises on any failure (callers wrap with
        wait_until when the server might still be coming up)."""
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/", timeout=timeout
        ) as response:
            return json.loads(response.read().decode("utf-8"))

    def wait_http_json(self, port, timeout=15.0):
        """http_get_json with retries — servers take a beat to bind."""
        def probe():
            try:
                return self.http_get_json(port)
            except (urllib.error.URLError, ConnectionError, OSError):
                return None
        return self.wait_until(
            probe, timeout, f"HTTP server on port {port} to answer GET /"
        )

    def runner(self, state, name):
        for entry in state.get("runners", []):
            if entry["name"] == name:
                return entry
        return None

    def instance(self, state, runner_name, branch):
        entry = self.runner(state, runner_name)
        if not entry:
            return None
        for inst in entry.get("instances", []):
            if inst["branch"] == branch:
                return inst
        return None

    def instance_running(self, runner_name, branch):
        inst = self.instance(self.state(), runner_name, branch)
        return inst if (inst and inst.get("status") == "running") else None

    def no_instance_running(self):
        state = self.state()
        for entry in state.get("runners", []):
            for inst in entry.get("instances", []):
                if inst.get("status") == "running":
                    return False
        return True

    # -- sandbox-scoped process cleanup --------------------------------------

    def kill_sandbox_servers(self):
        """SIGTERM (then SIGKILL) every fixture `server.py` whose cwd is
        inside the sandbox. The pattern matches on the script path
        alone (the fixtures start `python3 "$PWD/server.py"`, but
        macOS's python3 shim re-execs the interpreter under a different
        argv[0], so "python3" never appears in the live command line)
        and is scoped via lsof so we never touch unrelated processes
        that happen to match."""
        try:
            out = subprocess.run(
                ["pgrep", "-f", r"server\.py$"],
                capture_output=True, text=True,
            ).stdout
        except OSError:
            return
        # realpath both sides: mktemp hands out /var/folders/... but the
        # kernel (and therefore lsof) reports /private/var/folders/...,
        # so a raw startswith silently skipped every sandbox server —
        # leaking live listeners that poisoned the next run's port
        # probing.
        sandbox_real = os.path.realpath(SANDBOX)
        for pid_text in out.split():
            try:
                pid = int(pid_text)
            except ValueError:
                continue
            cwd = self._cwd_of(pid)
            if cwd is None or not os.path.realpath(cwd).startswith(sandbox_real):
                continue
            log(f"cleaning up leftover server pid={pid} cwd={cwd}")
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                continue
            time.sleep(0.3)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    @staticmethod
    def _cwd_of(pid):
        out = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            capture_output=True, text=True,
        ).stdout
        for line in out.splitlines():
            if line.startswith("n"):
                return line[1:]
        return None

    def cleanup(self):
        """Full teardown: app gone, fixture servers gone, socket file
        removed. Touches nothing outside the sandbox (plus our own
        socket file in /tmp)."""
        self.terminate()
        self.kill_sandbox_servers()
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Path helpers

def repo_dir(repo):
    return os.path.join(PROJECT_DIR, "repos", repo)


def worktree(repo, branch):
    return os.path.join(repo_dir(repo), branch)


def feature_dir(name):
    return os.path.join(PROJECT_DIR, "features", name)


def run_toml_path():
    return os.path.join(PROJECT_DIR, ".dreamux", "run.toml")


def read_run_toml():
    try:
        with open(run_toml_path(), "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# Scenarios

def scenario_boot(d):
    """App launches, socket pings, the demo project window is open."""
    d.launch_app()

    def project_window_up():
        state = d.state()
        active = state.get("activeProject")
        return active and active.get("name") == PROJECT_NAME

    d.wait_until(project_window_up, 30.0, f"project window for {PROJECT_NAME}")
    state = d.state()
    names = [p["name"] for p in state["projects"]]
    require(PROJECT_NAME in names, f"{PROJECT_NAME} not discovered: {names}")
    d.screenshot("project-window")


def scenario_repos_and_feature(d):
    """Import both seed repos, span feat-alpha across them, verify the
    worktree/symlink layout on disk and the workspace in app state."""
    for repo in ("portenv-server", "fixedport-server"):
        resp = d.cmd("addLocalRepo",
                     path=os.path.join(SEED_DIR, repo), name=repo)
        require(resp["defaultBranch"] == "main",
                f"{repo} default branch is {resp['defaultBranch']}, not main")
        # Bake the test identity into the shared .bare config so the
        # app's own merge commits work on machines without global git
        # config. Plain `git config` in a worktree writes to the common
        # config file, which every worktree shares.
        git("config", "user.name", "Dreamux E2E", cwd=worktree(repo, "main"))
        git("config", "user.email", "e2e@dreamux.local",
            cwd=worktree(repo, "main"))

    d.cmd("createFeature", name="feat-alpha",
          repos=["portenv-server", "fixedport-server"])

    for repo in ("portenv-server", "fixedport-server"):
        wt = worktree(repo, "feat-alpha")
        branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=wt)
        require(branch == "feat-alpha",
                f"{wt} is on branch {branch!r}, expected feat-alpha")
        # A linked worktree's .git is a pointer file, not a directory.
        dotgit = os.path.join(wt, ".git")
        require(os.path.isfile(dotgit), f"{dotgit} is not a worktree pointer file")

        link = os.path.join(feature_dir("feat-alpha"), repo)
        require(os.path.islink(link), f"{link} is not a symlink")
        require(os.path.isdir(os.path.realpath(link)),
                f"{link} does not resolve to a directory")
        require(os.path.realpath(link) == os.path.realpath(wt),
                f"{link} resolves to {os.path.realpath(link)}, expected {wt}")

    state = d.state()
    ws = next((w for w in state["workspaces"] if w["name"] == "feat-alpha"), None)
    require(ws is not None, "workspace feat-alpha missing from state")
    require(set(ws["linkedRepoIDs"]) == {"portenv-server", "fixedport-server"},
            f"feat-alpha linkedRepoIDs wrong: {ws['linkedRepoIDs']}")
    # feat-alpha has no plan behind it, so it renders under the sidebar's
    # "Ad hoc" group (the Features list is gone); the row body and controls
    # are unchanged, so this screenshot still documents a work-item row.
    d.screenshot("sidebar-feature")


def scenario_discovery(d):
    """Detect Run Config via the embedded terminal's fake claude, then
    verify the parsed runners. Note: feat-alpha already exists, and the
    fake claude anchors each runner's cwd at the first sorted worktree
    folder — feat-alpha here — which the later scenarios account for."""
    d.cmd("detectRunConfig")

    # The embedded terminal boots a real zsh before pasting the claude
    # line, so allow a generous window for run.toml to land.
    d.wait_until(lambda: os.path.isfile(run_toml_path()), 60.0,
                 ".dreamux/run.toml to be written by the fake claude")

    def both_runners_parsed():
        resp = d.cmd("reloadRunConfig")
        return {"portenv-server", "fixedport-server"} <= set(resp["runners"])

    d.wait_until(both_runners_parsed, 15.0,
                 "both runners to parse out of run.toml")

    state = d.state()
    portenv = d.runner(state, "portenv-server")
    fixed = d.runner(state, "fixedport-server")
    require(portenv["port"] == 4600,
            f"portenv-server port is {portenv.get('port')}, expected 4600")
    require(portenv.get("portEnv") == "PORTENV_SERVER_PORT",
            f"portenv-server portEnv wrong: {portenv.get('portEnv')}")
    require(fixed["port"] == 4700,
            f"fixedport-server port is {fixed.get('port')}, expected 4700")
    require("portEnv" not in fixed,
            f"fixedport-server should have no portEnv yet: {fixed.get('portEnv')}")
    d.screenshot("run-pane-detected")


def scenario_concurrent_ports(d):
    """Two worktrees of the same port_env app serving simultaneously on
    dynamically assigned ports."""
    d.cmd("createFeature", name="feat-beta", repos=["portenv-server"])

    resp = d.cmd("startFeature", name="feat-alpha")
    require(resp.get("started") is True, f"feat-alpha didn't start: {resp}")
    require(set(resp["runners"]) == {"portenv-server", "fixedport-server"},
            f"feat-alpha started wrong runners: {resp['runners']}")
    d.wait_until(lambda: d.instance_running("portenv-server", "feat-alpha"),
                 15.0, "portenv-server running on feat-alpha")
    d.wait_until(lambda: d.instance_running("fixedport-server", "feat-alpha"),
                 15.0, "fixedport-server running on feat-alpha")

    resp = d.cmd("startFeature", name="feat-beta")
    require(resp.get("started") is True, f"feat-beta didn't start: {resp}")
    require(resp["runners"] == ["portenv-server"],
            f"feat-beta should only start portenv-server: {resp['runners']}")
    d.wait_until(lambda: d.instance_running("portenv-server", "feat-beta"),
                 15.0, "portenv-server running on feat-beta")

    state = d.state()
    alpha = d.instance(state, "portenv-server", "feat-alpha")
    beta = d.instance(state, "portenv-server", "feat-beta")
    ports = {alpha.get("assignedPort"), beta.get("assignedPort")}
    require(ports == {4600, 4601},
            f"expected assignedPorts 4600/4601, got {ports}")

    body_alpha = d.wait_http_json(alpha["assignedPort"])
    body_beta = d.wait_http_json(beta["assignedPort"])
    for body in (body_alpha, body_beta):
        require(body["app"] == "portenv-server",
                f"unexpected app identity: {body}")
    require(body_alpha["cwd"].endswith("/feat-alpha"),
            f"port {alpha['assignedPort']} serves {body_alpha['cwd']}, expected .../feat-alpha")
    require(body_beta["cwd"].endswith("/feat-beta"),
            f"port {beta['assignedPort']} serves {body_beta['cwd']}, expected .../feat-beta")

    # Play also fires the runner's `open` target once the port answers
    # (suppressed-but-recorded in e2e mode): each worktree must open its
    # OWN port — that's the snippet's {port} placeholder resolving to
    # the per-instance assignment. fixedport-server has no open key, so
    # no localhost:4700 entry may appear.
    def opened():
        targets = set(d.state().get("openedTargets", []))
        return {"http://localhost:4600/", "http://localhost:4601/"} <= targets
    d.wait_until(opened, 30.0, "both worktrees' open targets to fire")
    require(not any("4700" in t for t in d.state().get("openedTargets", [])),
            "fixedport-server has no open key but something opened 4700")

    # URL opens land as in-app browser tabs inside the branch's own
    # workspace (not an external browser): each feature workspace must
    # hold exactly its own port's preview tab.
    def workspace_tabs(state, name):
        for ws in state.get("workspaces", []):
            if ws["name"] == name:
                return ws.get("webTabs", [])
        return []
    state = d.state()
    require(workspace_tabs(state, "feat-alpha") == ["http://localhost:4600/"],
            f"feat-alpha webTabs wrong: {workspace_tabs(state, 'feat-alpha')}")
    require(workspace_tabs(state, "feat-beta") == ["http://localhost:4601/"],
            f"feat-beta webTabs wrong: {workspace_tabs(state, 'feat-beta')}")

    # Surface the sidebar's running indicators for the screenshot.
    d.cmd("setSidebarMode", mode="workspace", workspace="feat-alpha")
    d.screenshot("two-worktrees-running")

    resp = d.cmd("stopFeature", name="feat-beta")
    require(resp["stopped"] == ["portenv-server"],
            f"stopFeature feat-beta stopped {resp['stopped']}")
    d.wait_until(lambda: not d.instance_running("portenv-server", "feat-beta"),
                 15.0, "portenv-server on feat-beta to stop")
    # feat-alpha must keep serving — per-instance stop, not per-runner.
    body = d.wait_http_json(4600)
    require(body["cwd"].endswith("/feat-alpha"),
            f"feat-alpha stopped serving after feat-beta stop: {body}")


def scenario_conflict_and_isolate(d):
    """Play on a second worktree of a fixed-port runner SWITCHES (the
    other worktree's instance stops, no dialog), reporting the
    displacement; then Claude isolates the port and both worktrees run
    side by side on 4700/4701."""
    # fixedport-server is still live on feat-alpha from the previous
    # scenario; start it if an earlier retry left it stopped.
    if not d.instance_running("fixedport-server", "feat-alpha"):
        d.cmd("startFeature", name="feat-alpha")
        d.wait_until(lambda: d.instance_running("fixedport-server", "feat-alpha"),
                     15.0, "fixedport-server running on feat-alpha")

    d.cmd("createFeature", name="feat-gamma", repos=["fixedport-server"])
    resp = d.cmd("startFeature", name="feat-gamma")
    require(resp.get("started") is True,
            f"feat-gamma should start (switching), got {resp}")
    displaced = resp.get("displaced") or []
    require(displaced == [{"runner": "fixedport-server", "fromBranch": "feat-alpha"}],
            f"switch should report displacing feat-alpha: {resp}")
    # The switch: gamma comes up, alpha's instance goes down.
    d.wait_until(lambda: d.instance_running("fixedport-server", "feat-gamma"),
                 15.0, "fixedport-server running on feat-gamma after switch")
    d.wait_until(lambda: not d.instance_running("fixedport-server", "feat-alpha"),
                 15.0, "fixedport-server displaced off feat-alpha")
    body = d.wait_http_json(4700)
    require(body["cwd"].endswith("/feat-gamma"),
            f"port 4700 should now serve feat-gamma, got {body['cwd']}")
    d.screenshot("switched-worktrees")

    # The switch notice's "Run both" path: the Run pane sends the
    # isolate prompt to the fake claude, which rewrites the marker line
    # in every fixedport-server worktree and appends port_env to
    # run.toml.
    d.cmd("isolateRunner", name="fixedport-server")
    d.wait_until(lambda: "FIXEDPORT_SERVER_PORT" in read_run_toml(), 60.0,
                 "run.toml to gain FIXEDPORT_SERVER_PORT")
    for branch in ("main", "feat-alpha", "feat-gamma"):
        server_py = os.path.join(worktree("fixedport-server", branch), "server.py")
        with open(server_py, "r", encoding="utf-8") as f:
            require("FIXEDPORT_SERVER_PORT" in f.read(),
                    f"{server_py} marker line was not rewritten")

    d.cmd("reloadRunConfig")
    state = d.state()
    require(d.runner(state, "fixedport-server").get("portEnv") == "FIXEDPORT_SERVER_PORT",
            "fixedport-server portEnv missing after reload")

    # The feat-gamma instance predates isolation: it runs the old
    # hardcoded-port code and the manager has no assignedPort recorded
    # for it, so a fresh instance would collide on 4700. Bounce it
    # (exactly what a user would do after isolating) so both instances
    # run the env-var code with tracked ports. Only fixedport-server
    # needs to quiesce — feat-alpha's portenv instance keeps serving
    # 4600 throughout, which is the whole point of flexible ports.
    d.cmd("stopFeature", name="feat-gamma")
    d.wait_until(
        lambda: not any(d.instance_running("fixedport-server", b)
                        for b in ("main", "feat-alpha", "feat-gamma")),
        15.0, "all fixedport-server instances to stop before the restart")
    resp = d.cmd("startFeature", name="feat-alpha")
    require(resp.get("started") is True, f"feat-alpha start failed: {resp}")
    d.wait_until(lambda: d.instance_running("fixedport-server", "feat-alpha"),
                 15.0, "fixedport-server back up on feat-alpha")

    resp = d.cmd("startFeature", name="feat-gamma")
    require(resp.get("started") is True,
            f"feat-gamma should start cleanly after isolation: {resp}")
    require(resp["runners"] == ["fixedport-server"],
            f"feat-gamma started wrong runners: {resp['runners']}")
    require(not resp.get("displaced"),
            f"isolated runner must not displace anything: {resp}")
    d.wait_until(lambda: d.instance_running("fixedport-server", "feat-gamma"),
                 15.0, "fixedport-server running on feat-gamma")

    state = d.state()
    alpha = d.instance(state, "fixedport-server", "feat-alpha")
    gamma = d.instance(state, "fixedport-server", "feat-gamma")
    ports = {alpha.get("assignedPort"), gamma.get("assignedPort")}
    require(ports == {4700, 4701},
            f"expected fixedport instances on 4700/4701, got {ports}")

    body_alpha = d.wait_http_json(alpha["assignedPort"])
    body_gamma = d.wait_http_json(gamma["assignedPort"])
    for body in (body_alpha, body_gamma):
        require(body["app"] == "fixedport-server",
                f"unexpected app identity: {body}")
    require(body_alpha["cwd"].endswith("/feat-alpha"),
            f"port {alpha['assignedPort']} serves {body_alpha['cwd']}")
    require(body_gamma["cwd"].endswith("/feat-gamma"),
            f"port {gamma['assignedPort']} serves {body_gamma['cwd']}")
    require(body_alpha["cwd"] != body_gamma["cwd"],
            "both fixedport instances claim the same cwd")
    d.screenshot("isolated-both-running")


def scenario_merge_and_cleanup(d):
    """Commit work on feat-alpha, merge it into main through the app,
    document the merge sheet, then clean the feature up everywhere."""
    # Quiesce everything. Stop feat-gamma first so the fixedport user
    # stop command (a pkill anchored to one worktree's server.py path)
    # only fires once everything on feat-alpha is going down anyway.
    d.cmd("stopFeature", name="feat-gamma")
    d.wait_until(lambda: not d.instance_running("fixedport-server", "feat-gamma"),
                 15.0, "feat-gamma to stop")
    d.cmd("stopFeature", name="feat-alpha")
    d.wait_until(d.no_instance_running, 15.0, "all runners to stop")

    # Real work on the feature branch, committed by the driver.
    wt = worktree("portenv-server", "feat-alpha")
    payload = os.path.join(wt, "E2E-NOTES.md")
    with open(payload, "w", encoding="utf-8") as f:
        f.write("e2e merge payload for feat-alpha\n")
    git("add", "-A", cwd=wt)
    git("commit", "-m", "feat-alpha: add e2e merge payload", cwd=wt)

    resp = d.cmd("mergeFeature", name="feat-alpha", repo="portenv-server")
    require(resp["outcome"] == "merged",
            f"mergeFeature outcome was {resp['outcome']}, expected merged")

    main_wt = worktree("portenv-server", "main")
    head_log = git("log", "--oneline", "-n", "5", cwd=main_wt)
    require("Merge branch 'feat-alpha'" in head_log,
            f"merge commit missing from main log:\n{head_log}")
    require(os.path.isfile(os.path.join(main_wt, "E2E-NOTES.md")),
            "merged file did not land in the main worktree")

    d.cmd("openMergeSheet", name="feat-alpha")
    time.sleep(2.0)  # sheet animation + its async git probes
    d.screenshot("merge-sheet")

    d.cmd("cleanupFeature", name="feat-alpha")

    for repo in ("portenv-server", "fixedport-server"):
        wt_path = worktree(repo, "feat-alpha")
        require(not os.path.exists(wt_path), f"worktree still on disk: {wt_path}")
        branches = git("branch", "--list", "feat-alpha",
                       cwd=worktree(repo, "main"))
        require(branches == "", f"branch feat-alpha survived in {repo}: {branches!r}")
    require(not os.path.exists(feature_dir("feat-alpha")),
            "features/feat-alpha aggregation dir still on disk")

    state = d.state()
    names = [w["name"] for w in state["workspaces"]]
    require("feat-alpha" not in names,
            f"workspace feat-alpha still in state: {names}")

    # cleanupFeature runs the merge sheet's own cleanup code (MergeFlow)
    # but can't press its Done button, so the (now stale) sheet is still
    # attached and would hijack the screenshot. Relaunch instead — which also
    # proves the cleanup survives a restart (worktree rediscovery finds
    # feat-beta and feat-gamma but not feat-alpha).
    self_quit = d.cmd("quit")
    require(self_quit.get("ok") is True, "quit before relaunch failed")
    d.wait_for_exit()
    d.launch_app()

    def relaunched_without_alpha():
        state = d.state()
        active = state.get("activeProject")
        if not active or active.get("name") != PROJECT_NAME:
            return False
        names = [w["name"] for w in state["workspaces"]]
        return "feat-alpha" not in names and {"feat-beta", "feat-gamma"} <= set(names)

    d.wait_until(relaunched_without_alpha, 30.0,
                 "relaunched window showing feat-beta/feat-gamma but not feat-alpha")
    d.screenshot("after-cleanup")


def scenario_publish_pr(d):
    """Publish a feature as a PR against a bare 'GitHub' remote (the
    fake gh), watch a fresh merge sheet resume the PR state, merge the
    PR remote-side, and verify cleanup fast-forwards local main."""
    # The remote must be bare: MergeFlow.publish pushes the feature
    # branch to origin, and git refuses pushes into a non-bare checkout.
    remote = os.path.join(SANDBOX, "remotes", "portenv-server.git")
    os.makedirs(os.path.dirname(remote), exist_ok=True)
    git("clone", "--bare", "--quiet",
        os.path.join(SEED_DIR, "portenv-server"), remote, cwd=SANDBOX)

    # Import from the bare path directly: addLocalRepo is a local
    # `git clone --bare`, so the imported repo's origin IS the bare
    # remote — exactly where publish must push and the fake gh looks
    # for PR records. Distinct name so the existing portenv-server
    # repo (origin = the non-bare seed dir) stays untouched.
    resp = d.cmd("addLocalRepo", path=remote, name="pr-server")
    require(resp["defaultBranch"] == "main",
            f"pr-server default branch is {resp['defaultBranch']}, not main")
    origin = git("remote", "get-url", "origin", cwd=worktree("pr-server", "main"))
    require(os.path.realpath(origin) == os.path.realpath(remote),
            f"pr-server origin is {origin}, expected the bare remote {remote}")
    git("config", "user.name", "Dreamux E2E", cwd=worktree("pr-server", "main"))
    git("config", "user.email", "e2e@dreamux.local",
        cwd=worktree("pr-server", "main"))

    # Real work on the feature branch, committed by the driver.
    d.cmd("createFeature", name="feat-pr", repos=["pr-server"])
    wt = worktree("pr-server", "feat-pr")
    with open(os.path.join(wt, "PR-NOTES.md"), "w", encoding="utf-8") as f:
        f.write("e2e PR payload for feat-pr\n")
    git("add", "-A", cwd=wt)
    git("commit", "-m", "feat-pr: add e2e PR payload", cwd=wt)

    # Document the sheet offering the Create PR path (state asserts
    # happen via publishFeature/featurePRStatus, never via pixels).
    d.cmd("openMergeSheet", name="feat-pr")
    time.sleep(2.0)  # sheet animation + its async pre-check (gh probe)
    d.screenshot("merge-sheet-create-pr")

    resp = d.cmd("publishFeature", name="feat-pr", repo="pr-server")
    require(resp["state"] == "prOpen",
            f"publishFeature state is {resp.get('state')}, expected prOpen: {resp}")
    url = resp.get("url", "")
    require(url.startswith("https://fake-gh.example/"),
            f"unexpected PR url: {url!r}")

    # On disk: the push landed the branch in the bare remote, and the
    # fake gh recorded the PR inside it.
    remote_head = git("rev-parse", "--verify", "refs/heads/feat-pr", cwd=remote)
    local_head = git("rev-parse", "--verify", "refs/heads/feat-pr", cwd=wt)
    require(remote_head == local_head,
            f"remote feat-pr at {remote_head}, local at {local_head}")
    require(os.path.isfile(os.path.join(remote, "fake-prs", "feat-pr.json")),
            "fake-prs/feat-pr.json missing from the bare remote")

    resp = d.cmd("featurePRStatus", name="feat-pr", repo="pr-server")
    require(resp["state"] == "prOpen", f"PR not open after publish: {resp}")
    require(resp.get("url") == url, f"PR url drifted: {resp.get('url')} != {url}")

    # A second openMergeSheet while the first (now stale) sheet is
    # still attached would no-op — same constraint merge-and-cleanup
    # works around. Relaunch instead, which also proves the PR state
    # is resumed from gh, not from in-memory session state.
    resp = d.cmd("quit")
    require(resp.get("ok") is True, "quit before PR-resume relaunch failed")
    d.wait_for_exit()
    d.launch_app()

    def feat_pr_rediscovered():
        state = d.state()
        active = state.get("activeProject")
        if not active or active.get("name") != PROJECT_NAME:
            return False
        return "feat-pr" in [w["name"] for w in state["workspaces"]]

    d.wait_until(feat_pr_rediscovered, 30.0,
                 "relaunched window to rediscover feat-pr")

    # Fresh sheet on the fresh session: initializeStates resumes prOpen.
    d.cmd("openMergeSheet", name="feat-pr")
    time.sleep(2.0)
    d.screenshot("pr-open-resumed")

    # "Merge the PR on GitHub": move the remote's main to the PR head.
    # The fake gh derives MERGED from ancestry in the remote, so no
    # other bookkeeping is needed.
    git("update-ref", "refs/heads/main", remote_head, cwd=remote)

    resp = d.cmd("featurePRStatus", name="feat-pr", repo="pr-server")
    require(resp["state"] == "prMerged",
            f"PR not merged after remote update-ref: {resp}")
    require(resp.get("url") == url,
            f"merged PR url drifted: {resp.get('url')} != {url}")

    # Cleanup from prMerged: fast-forward local main from origin first,
    # then the usual worktree/branch/workspace teardown.
    d.cmd("cleanupFeature", name="feat-pr")

    main_wt = worktree("pr-server", "main")
    require(os.path.isfile(os.path.join(main_wt, "PR-NOTES.md")),
            "cleanup did not fast-forward local main from the merged PR")
    require(not os.path.exists(wt), f"worktree still on disk: {wt}")
    branches = git("branch", "--list", "feat-pr", cwd=main_wt)
    require(branches == "", f"branch feat-pr survived cleanup: {branches!r}")
    require(not os.path.exists(feature_dir("feat-pr")),
            "features/feat-pr aggregation dir still on disk")
    state = d.state()
    names = [w["name"] for w in state["workspaces"]]
    require("feat-pr" not in names, f"workspace feat-pr still in state: {names}")

    # The stale sheet from the resume screenshot is still attached and
    # would hijack the final screenshot — relaunch (the merge-and-cleanup
    # precedent), which also proves feat-pr is not rediscovered.
    resp = d.cmd("quit")
    require(resp.get("ok") is True, "quit before post-cleanup relaunch failed")
    d.wait_for_exit()
    d.launch_app()

    def relaunched_without_feat_pr():
        state = d.state()
        active = state.get("activeProject")
        if not active or active.get("name") != PROJECT_NAME:
            return False
        names = [w["name"] for w in state["workspaces"]]
        return "feat-pr" not in names and {"feat-beta", "feat-gamma"} <= set(names)

    d.wait_until(relaunched_without_feat_pr, 30.0,
                 "relaunched window showing feat-beta/feat-gamma but not feat-pr")
    d.screenshot("after-pr-cleanup")


def scenario_flows(d):
    """Flows pane: a synthetic registry session plus real emit-socket
    signals render a running lane, then a notification flips it to
    needs-you, then a synthetic transcript + subagent meta on disk let
    zoomFlow exercise the lazy full-replay tailer.

    The lane's cwd must resolve to a real workspace or FlowStore's
    isInProject scoping drops it (see FlowWiring.workspaceID) — so this
    creates its own feature (flows-demo, on the portenv-server repo
    already imported by scenario_repos_and_feature) rather than reusing
    a raw sandbox path."""
    resp = d.cmd("createFeature", name="flows-demo", repos=["portenv-server"])
    cwd = resp["featureDirectory"]

    session_id = "e2e-session-1"
    registry_path = os.path.join(CLAUDE_HOME, "sessions", f"{os.getpid()}.json")

    def write_registry_entry(status):
        # pid = this driver process, alive for the whole scenario, so
        # the app's liveness probe (kill(pid, 0)) keeps the entry live.
        with open(registry_path, "w", encoding="utf-8") as f:
            json.dump({
                "pid": os.getpid(), "sessionId": session_id, "cwd": cwd,
                "status": status, "kind": "interactive", "name": "flows-demo",
            }, f)

    def emit(kind, payload):
        """Send one envelope over the real hook-signal socket — the
        same wire a `claude` hook uses."""
        envelope = {"action": "emit", "signal": {
            "kind": kind, "source": "claude.hooks", "severity": "info",
            "tags": {"cwd": cwd}, "payload": payload,
        }}
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(EMIT_SOCKET_PATH)
        s.sendall((json.dumps(envelope) + "\n").encode("utf-8"))
        s.recv(256)
        s.close()

    # 1. A live "busy" claude session in the registry.
    write_registry_entry("busy")

    # 2. A subagent start over the emit socket.
    emit("agent.started", {
        "session_id": session_id, "agent_id": "e2e-a1", "agent_type": "Explore",
    })

    # 3. Wait for the 3s registry poll (which names the lane "flows-demo"
    # from the entry, not just its session id) AND the live signal (the
    # agent node) to both land.
    def lane_named_with_agent():
        state = d.cmd("flowsState")
        lane = next((l for l in state["lanes"] if l["id"] == f"session-{session_id}"), None)
        if (lane and lane["title"] == "flows-demo"
                and any(n["id"] == "agent-e2e-a1" for n in lane["nodes"])):
            return state
        return None

    state = d.wait_until(lane_named_with_agent, 10.0,
                          "flows-demo lane with an agent-e2e-a1 node in flowsState")
    lane = next(l for l in state["lanes"] if l["id"] == f"session-{session_id}")
    require(lane["status"] == "running", f"lane should be running, got {lane['status']}")
    require(any(n["id"] == "agent-e2e-a1" and n["status"] == "running" for n in lane["nodes"]),
            "agent node missing or not running")
    require(state["running"] >= 1, "running aggregate should count the lane")

    d.cmd("setSidebarMode", mode="flows")
    time.sleep(1.0)
    d.screenshot("flows-overview")

    # 4. Needs-you: flip the registry entry to waiting + a notification.
    write_registry_entry("waiting")
    emit("session.notification", {
        "session_id": session_id, "message": "Claude needs permission to run npm",
    })

    def needs_you():
        state = d.cmd("flowsState")
        return state if state.get("needsYou", 0) >= 1 else None

    state = d.wait_until(needs_you, 10.0, "needsYou aggregate to rise")
    lane = next(l for l in state["lanes"] if l["id"] == f"session-{session_id}")
    require(lane.get("detail") == "Claude needs permission to run npm",
            "notification detail missing")
    time.sleep(1.0)
    d.screenshot("flows-needs-you")

    # 5. Zoom: exercise the lazy FULL-REPLAY tailer + subagent-meta join —
    # paths the hot-tail steps above never touch. This session's hot
    # tailer started (step 1, EOF-seek) before any transcript file
    # existed on disk, retried once, then went dormant (see
    # ClaudeTranscriptTailer's one-retry-then-dormant policy); only
    # `zoomFlow`'s lazy tail (`FlowTailerPool.ensureLazyTail`,
    # `start(replayExisting: true)`) ever opens it. `slug` mirrors
    # `ClaudeHome.projectSlug`'s non-alphanumeric→dash rule so the file
    # lands exactly where the app's tailer pool will look for it.
    slug = "".join(ch if ch.isalnum() else "-" for ch in cwd)
    project_dir = os.path.join(CLAUDE_HOME, "projects", slug)
    os.makedirs(project_dir, exist_ok=True)
    transcript_path = os.path.join(project_dir, f"{session_id}.jsonl")
    ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    transcript_lines = [
        # Agent/Task tool_use -> .agentSpawned, joined to agent-e2e-a1
        # (already on the lane from step 2's hook emit) via the subagent
        # meta's toolUseId below.
        {
            "type": "assistant", "timestamp": ts,
            "message": {"content": [{
                "type": "tool_use", "id": "toolu-e2e-agent1", "name": "Task",
                "input": {"subagent_type": "Explore", "description": "Explore the codebase"},
            }]},
        },
        # Plain tool_use -> .toolStarted, sets the SESSION node's
        # lastActivity — the one signal in this scenario that only a
        # transcript replay can produce (none of the emit-socket hooks
        # above ever touch it).
        {
            "type": "assistant", "timestamp": ts,
            "message": {"content": [{
                "type": "tool_use", "id": "toolu-e2e-bash1", "name": "Bash",
                "input": {"command": "npm test"},
            }]},
        },
        {
            "type": "user", "timestamp": ts,
            "message": {"content": [{
                "type": "tool_result", "tool_use_id": "toolu-e2e-bash1", "is_error": False,
            }]},
        },
    ]
    with open(transcript_path, "w", encoding="utf-8") as f:
        for line in transcript_lines:
            f.write(json.dumps(line) + "\n")

    subagents_dir = os.path.join(project_dir, session_id, "subagents")
    os.makedirs(subagents_dir, exist_ok=True)
    with open(os.path.join(subagents_dir, "agent-e2e-a1.meta.json"), "w", encoding="utf-8") as f:
        json.dump({
            "agentType": "Explore", "description": "Exploring the repository",
            "toolUseId": "toolu-e2e-agent1", "spawnDepth": 1,
        }, f)

    write_registry_entry("busy")

    # Smoke-test Monaco/openFileTab against an absolute path OUTSIDE the
    # project (the transcript lives under DREAMUX_CLAUDE_HOME, not the
    # feature worktree) — the same `openFileTab` call the zoom detail
    # view's "Open transcript" button makes.
    resp = d.cmd("openFile", path=transcript_path)
    require(resp.get("ok"), "openFile should accept an absolute path outside the project")

    d.cmd("zoomFlow", laneID=f"session-{session_id}")

    def zoomed_and_enriched():
        state = d.cmd("flowsState")
        lane = next((l for l in state["lanes"] if l["id"] == f"session-{session_id}"), None)
        if not lane:
            return None
        session_node = next((n for n in lane["nodes"] if n["id"] == "session"), None)
        agent_node = next((n for n in lane["nodes"] if n["id"] == "agent-e2e-a1"), None)
        # Also wait for the 3s registry poll to catch up to the "busy"
        # flip above — otherwise the screenshot below can land between
        # polls and still show the stale "waiting" status.
        if (lane.get("status") == "running"
                and session_node and session_node.get("lastActivity")
                and agent_node and agent_node.get("label") == "Explore"):
            return lane
        return None

    lane = d.wait_until(
        zoomed_and_enriched, 15.0,
        "lane running + session lastActivity + agent-e2e-a1 label enriched after zoomFlow's full transcript replay")
    require(lane.get("detailUnavailable") is not True,
            "lane detail should still be trustworthy after the zoom replay")
    node_ids = {n["id"] for n in lane["nodes"]}
    require({"src", "session", "agent-e2e-a1", "drain"} <= node_ids,
            f"expected DAG nodes missing, got {node_ids}")

    time.sleep(1.0)
    d.screenshot("flows-zoom")

    d.cmd("zoomFlow", laneID=None)

    # 6. Loop: append >=3 failing "swift test" pairs (same Bash
    # leading-token signature "Bash:swift") to the SAME transcript file
    # via `open(..., "a")` — the hot tailer only reads newly-appended
    # bytes (see ClaudeTranscriptTailer's kqueue .write/.extend watch);
    # rewriting the file would desync its byte offset and drop lines.
    # The registry entry is still "busy" from step 5's write (nothing
    # since has flipped it), but re-flip defensively: only a hot
    # (busy/waiting) session keeps FlowTailerPool's transcript tailer
    # alive to ever notice this append (see ProjectSession's
    # `pool?.reconcile(hot:)` filter).
    write_registry_entry("busy")

    def swift_test_pair(toolu_id, is_error):
        pair_ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        return [
            {
                "type": "assistant", "timestamp": pair_ts,
                "message": {"content": [{
                    "type": "tool_use", "id": toolu_id, "name": "Bash",
                    "input": {"command": "swift test --filter Snip"},
                }]},
            },
            {
                "type": "user", "timestamp": pair_ts,
                "message": {"content": [{
                    "type": "tool_result", "tool_use_id": toolu_id, "is_error": is_error,
                }]},
            },
        ]

    with open(transcript_path, "a", encoding="utf-8") as f:
        for i in range(3):
            for line in swift_test_pair(f"toolu-e2e-loop-fail-{i}", True):
                f.write(json.dumps(line) + "\n")

    # LoopDetector.detect (LoopDetector.swift) requires >=3 total,
    # >=2 errors, AND the window's most recent completion of the
    # signature to be an error — 3 failing pairs satisfies all three.
    def loop_edge_detected():
        state = d.cmd("flowsState")
        lane = next((l for l in state["lanes"] if l["id"] == f"session-{session_id}"), None)
        if not lane:
            return None
        edge = next((e for e in lane["edges"]
                     if e["kind"] == "loop" and e["from"] == "session" and e["to"] == "session"), None)
        if edge and edge.get("iterations", 0) >= 3 and edge.get("label") == "Bash:swift":
            return state
        return None

    state = d.wait_until(loop_edge_detected, 15.0,
                          "session lane loop edge kind=loop, iterations>=3, label=Bash:swift")
    lane = next(l for l in state["lanes"] if l["id"] == f"session-{session_id}")
    loop_edge = next(e for e in lane["edges"] if e["kind"] == "loop")
    require(loop_edge["iterations"] >= 3, f"expected iterations>=3, got {loop_edge['iterations']}")
    require(loop_edge["label"] == "Bash:swift", f"expected label Bash:swift, got {loop_edge['label']}")

    time.sleep(1.0)
    d.screenshot("flows-loop-overview")

    # 7. Zoom into the looping lane: FlowDetailView's Canvas special-cases
    # edge.from == edge.to into a dashed 270 degree arc plus a "loop x N"
    # label overlay (see FlowDetailView.swift / task-3-report.md) instead
    # of the degenerate zero-length line a straight edge would draw.
    #
    # NOT asserting a specific `iterations` count here (only presence,
    # below): `zoomFlow` always triggers FlowTailerPool.ensureLazyTail's
    # FULL replay from byte 0 (ClaudeTranscriptTailer.start(replayExisting:
    # true)), and FlowStore.toolCompletionRings has no toolUseID dedup —
    # every tool completion the hot tailer already delivered gets
    # redelivered and re-counted by the replay. Observed: the ×3 this
    # lane earned above from the hot tail becomes ×6 post-zoom, since the
    # 3 failing pairs get counted twice. This is a real pre-existing gap
    # in the replay path (not introduced by this scenario) — flagged in
    # task-7-report.md as a follow-up, out of scope for this e2e task.
    d.cmd("zoomFlow", laneID=f"session-{session_id}")

    def zoomed_lane_has_loop():
        state = d.cmd("flowsState")
        lane = next((l for l in state["lanes"] if l["id"] == f"session-{session_id}"), None)
        if lane and any(e["kind"] == "loop" for e in lane["edges"]):
            return state
        return None

    d.wait_until(zoomed_lane_has_loop, 10.0, "loop edge still present in flowsState after zoomFlow")
    time.sleep(1.0)
    d.screenshot("flows-loop-zoom")

    d.cmd("zoomFlow", laneID=None)

    # 8. Clear: one successful "swift test" call disqualifies the
    # signature (LoopDetector requires the window's LATEST completion of
    # a qualifying signature to be an error) — the edge must disappear
    # from flowsState entirely, proving the badge/arc aren't sticky once
    # the failure streak breaks.
    with open(transcript_path, "a", encoding="utf-8") as f:
        for line in swift_test_pair("toolu-e2e-loop-clear", False):
            f.write(json.dumps(line) + "\n")

    def loop_edge_cleared():
        state = d.cmd("flowsState")
        lane = next((l for l in state["lanes"] if l["id"] == f"session-{session_id}"), None)
        if lane is None:
            return None
        return state if not any(e["kind"] == "loop" for e in lane["edges"]) else None

    d.wait_until(loop_edge_cleared, 15.0, "loop edge to disappear from flowsState after a success pair")


def scenario_plan_gate(d):
    """Drive a real plan through the queue to atGate and verify the
    Flows gate card: plan lane's gate node waiting in flowsState, the
    expanded card in the overview, and the gate-preselected inspector
    in zoom. Buttons aren't clickable from the harness — their channels
    are unit/scenario-covered elsewhere; this pins the rendered state."""
    plans_dir = os.path.join(PROJECT_DIR, "docs", "plans")
    os.makedirs(plans_dir, exist_ok=True)
    plan_rel = "docs/plans/2026-07-06-gate-demo.md"
    plan_abs = os.path.join(PROJECT_DIR, plan_rel)

    def write_plan(checked):
        mark = "x" if checked else " "
        with open(plan_abs, "w", encoding="utf-8") as f:
            f.write(
                "# Gate Demo\n\n"
                "### Task 1: Do the work\n\n"
                f"- [{mark}] Step one\n"
                f"- [{mark}] Step two\n")

    write_plan(checked=False)
    docs = d.cmd("listDocs")
    entry = next((doc for doc in docs["docs"] if doc["path"] == plan_rel), None)
    require(entry is not None and entry["status"] == "ready",
            f"gate-demo plan should be ready, got {entry}")

    d.cmd("enqueuePlan", path=plan_rel)
    d.cmd("startQueue")

    # runPlan provisions worktrees on every repo (branch = filename
    # minus date prefix -> gate-demo) and types the fake claude; wait
    # for the launch to land.
    def queue_running():
        qs = d.cmd("queueState")
        return qs if qs["state"] == "running" and qs.get("current") == plan_rel else None
    d.wait_until(queue_running, 30.0, "queue running the gate-demo plan")

    # `queue.state`/`current` above flip SYNCHRONOUSLY inside start()/
    # launch(), before the queue's own async Task even begins awaiting
    # runPlan (FeatureProvisioner.provision -> ledger.record). So
    # queue_running() alone races the actual worktree creation — confirmed
    # by a real run that failed writing into the not-yet-provisioned
    # worktree. Wait for the doc's status to leave "ready", which only
    # happens once PlanRunCoordinator.runPlan has awaited provisioning and
    # written the ledger record (docStore.status derives "running" from
    # hasRun + featureExists), before touching the worktree on disk.
    def plan_provisioned():
        docs = d.cmd("listDocs")
        entry = next((doc for doc in docs["docs"] if doc["path"] == plan_rel), None)
        return entry if entry and entry["status"] != "ready" else None
    d.wait_until(plan_provisioned, 30.0,
                 "gate-demo plan status to leave ready (worktree provisioned + ledger recorded)")

    # Real committed work on the feature branch so the card's diff stat
    # has true numbers (+2 -0, 1 file; the other repos' gate-demo
    # branches have no commits and contribute zeros).
    wt = worktree("portenv-server", "gate-demo")
    with open(os.path.join(wt, "GATE-NOTES.md"), "w", encoding="utf-8") as f:
        f.write("gate card payload\nsecond line\n")
    git("add", "-A", cwd=wt)
    git("commit", "-m", "gate-demo: payload", cwd=wt)

    # All boxes checked -> statusForPlan (which refreshes DocStore
    # itself) reads awaitingReview -> queueState's synchronous tick
    # flips running -> atGate.
    write_plan(checked=True)
    def at_gate():
        qs = d.cmd("queueState")
        return qs if qs["state"] == "atGate" else None
    d.wait_until(at_gate, 15.0, "queue to reach atGate")

    # The card's data condition + the unified badge count.
    state = d.cmd("flowsState")
    plan_lane_id = f"plan-{plan_rel}"
    lane = next((l for l in state["planLanes"] if l["id"] == plan_lane_id), None)
    require(lane is not None,
            f"plan lane {plan_lane_id} missing from planLanes")
    gate = next((n for n in lane["nodes"] if n["id"] == "gate"), None)
    require(gate is not None and gate["status"] == "waiting",
            f"gate node should be waiting, got {gate}")
    require(state.get("boardNeedsYou", 0) >= 1,
            "board needs-you should count the waiting gate")

    # Overview: the expanded card under the gate-demo lane.
    d.cmd("setSidebarMode", mode="flows")
    time.sleep(1.5)  # render + the card's one-shot diff-stat fetch
    d.screenshot("flows-gate-card")

    # Zoom: gate node preselected -> inspector carries the same card.
    d.cmd("zoomFlow", laneID=plan_lane_id)
    time.sleep(1.5)
    d.screenshot("flows-gate-zoom")
    d.cmd("zoomFlow", laneID=None)

    d.cmd("stopQueue")


def scenario_quit(d):
    """The app quits cleanly on command."""
    resp = d.cmd("quit")
    require(resp.get("ok") is True, f"quit refused: {resp}")
    d.wait_for_exit()


SCENARIOS = [
    ("boot", scenario_boot),
    ("repos-and-feature", scenario_repos_and_feature),
    ("discovery", scenario_discovery),
    ("concurrent-ports", scenario_concurrent_ports),
    ("conflict-and-isolate", scenario_conflict_and_isolate),
    ("merge-and-cleanup", scenario_merge_and_cleanup),
    ("publish-pr", scenario_publish_pr),
    ("flows", scenario_flows),
    ("plan-gate", scenario_plan_gate),
    ("quit", scenario_quit),
]


def dump_failure_context(d, scenario_name):
    """Best-effort debugging artifacts when a scenario fails: the last
    state snapshot and a screenshot of whatever is on screen."""
    try:
        state = d.state()
        path = os.path.join(ARTIFACTS, f"failure-{scenario_name}-state.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, sort_keys=True)
    except Exception:
        pass
    try:
        d.screenshot(f"failure-{scenario_name}")
    except Exception:
        pass


def main():
    os.makedirs(ARTIFACTS, exist_ok=True)
    driver = Driver()
    results = []
    failed = False

    try:
        for name, scenario in SCENARIOS:
            if failed:
                results.append((name, "SKIP"))
                print(f"SKIP {name}", flush=True)
                continue
            print(f"=== scenario: {name}", flush=True)
            try:
                scenario(driver)
            except Exception as e:
                failed = True
                results.append((name, "FAIL"))
                print(f"FAIL {name}: {e}", flush=True)
                dump_failure_context(driver, name)
            else:
                results.append((name, "PASS"))
                print(f"PASS {name}", flush=True)
    finally:
        driver.cleanup()

    print("\n--- e2e summary ---", flush=True)
    for name, status in results:
        print(f"{status:4s} {name}", flush=True)
    print(f"artifacts: {ARTIFACTS}", flush=True)

    if failed:
        print(f"sandbox kept for debugging: {SANDBOX}", flush=True)
        return 1
    shutil.rmtree(SANDBOX, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
