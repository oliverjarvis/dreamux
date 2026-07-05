#!/usr/bin/env bun
/**
 * dreamux-signals-mcp — read-only MCP server over the Dreamux signal log.
 *
 * The Dreamux app already maintains a SQLite-backed `signals.db` at a
 * well-known location (per-bundle in `~/Library/Application Support/`).
 * This script opens that DB read-only and exposes a small set of
 * query tools so external Claude Code agents can inspect the same
 * backpressure Dreamux's internal Flows engine sees: terminal output,
 * manifest-driven board items, lint findings, second-order signals
 * emitted by flows, and so on.
 *
 * v1 is read-only. A future version can add `signals_emit` (so
 * external agents can write a finding back into the bus) once we
 * decide on a write-side bridge — straight DB writes wouldn't
 * notify the running app's in-memory subscribers.
 *
 * Wire it up with:
 *   claude mcp add dreamux-signals bun run /absolute/path/to/clayspace/mcp/dreamux-signals-mcp.ts
 *
 * Override the DB path via `DREAMUX_SIGNALS_DB` if you have multiple
 * Dreamux builds (debug/staging/tagged).
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Database } from "bun:sqlite";
import { readdirSync, statSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { connect as netConnect } from "node:net";

// ---------- DB discovery ----------

/**
 * Resolve the SQLite path the Dreamux app writes to. Order:
 *   1. `DREAMUX_SIGNALS_DB` env var (explicit override).
 *   2. Production bundle: `~/Library/Application Support/com.dreamux.Dreamux/signals.db`.
 *   3. Most-recently-modified `signals.db` under any com.dreamux.* bundle dir
 *      (catches debug / staging / tagged builds during development).
 */
function resolveDBPath(): string {
  const override = process.env.DREAMUX_SIGNALS_DB;
  if (override) {
    if (!existsSync(override)) {
      throw new Error(`DREAMUX_SIGNALS_DB does not exist: ${override}`);
    }
    return override;
  }

  const root = join(homedir(), "Library", "Application Support");
  const productionPath = join(root, "com.dreamux.Dreamux", "signals.db");
  if (existsSync(productionPath)) return productionPath;

  // Scan for any com.dreamux.* bundle that has a signals.db; pick the
  // freshest. Useful when the user is on a tagged dev build.
  let candidates: { path: string; mtime: number }[] = [];
  let entries: string[] = [];
  try {
    entries = readdirSync(root);
  } catch {
    throw new Error(`Cannot read ${root}`);
  }
  for (const entry of entries) {
    if (!entry.startsWith("com.dreamux.")) continue;
    const candidate = join(root, entry, "signals.db");
    if (!existsSync(candidate)) continue;
    try {
      const stat = statSync(candidate);
      candidates.push({ path: candidate, mtime: stat.mtimeMs });
    } catch {
      // skip
    }
  }
  if (candidates.length === 0) {
    throw new Error(
      `No Dreamux signals.db found under ${root}. Open the Dreamux app once or ` +
        `set DREAMUX_SIGNALS_DB to the file's absolute path.`,
    );
  }
  candidates.sort((a, b) => b.mtime - a.mtime);
  return candidates[0].path;
}

const DB_PATH = resolveDBPath();

/**
 * Emit-side socket lives under `/tmp/dreamux-emit-<bundle-id>.sock`.
 * Couldn't be next to `signals.db` because macOS's Unix-domain
 * `sun_path` is hard-capped at 104 bytes and the Application
 * Support path blows that limit for tagged builds. The Dreamux app
 * writes to the same path; both sides derive the bundle id from
 * the DB path's parent directory.
 *
 * Override via `DREAMUX_SIGNALS_EMIT_SOCKET` if needed.
 */
function resolveEmitSocketPath(): string {
  const override = process.env.DREAMUX_SIGNALS_EMIT_SOCKET;
  if (override) return override;
  // DB path: ~/Library/Application Support/<bundle-id>/signals.db
  const bundleID = dirname(DB_PATH).split("/").pop() || "com.dreamux.Dreamux";
  return `/tmp/dreamux-emit-${bundleID}.sock`;
}
const EMIT_SOCKET_PATH = resolveEmitSocketPath();

// ---------- Project scope ----------

/**
 * Project filter applied to every query. Defaults to the process's
 * working directory so a `.mcp.json` at a project root yields a
 * project-scoped view automatically. Override:
 *   - `DREAMUX_PROJECT_DIR=<path>` to scope to a different project.
 *   - `DREAMUX_SIGNALS_ALL_PROJECTS=1` to drop the filter entirely.
 *
 * Dreamux's emitters (services, manifests, checks, flows) all set a
 * `project_dir` tag carrying the env's worktree path; this filter
 * matches against that.
 */
function resolveProjectScope(): string | null {
  if (
    process.env.DREAMUX_SIGNALS_ALL_PROJECTS === "1" ||
    process.env.DREAMUX_SIGNALS_ALL_PROJECTS === "true"
  ) {
    return null;
  }
  const explicit = process.env.DREAMUX_PROJECT_DIR;
  if (explicit && explicit.length > 0) return explicit;
  return process.cwd();
}

const PROJECT_SCOPE = resolveProjectScope();
process.stderr.write(
  `dreamux-signals-mcp: using db ${DB_PATH}\n` +
    (PROJECT_SCOPE
      ? `dreamux-signals-mcp: scoping to project_dir=${PROJECT_SCOPE}\n`
      : "dreamux-signals-mcp: no project filter (DREAMUX_SIGNALS_ALL_PROJECTS)\n"),
);

// `readonly: true` honours WAL — the Dreamux app remains the sole
// writer; we never block its emits.
const db = new Database(DB_PATH, { readonly: true });

// ---------- Row shape ----------

interface SignalRow {
  id: string;
  source: string;
  kind: string;
  ts: number; // ms since epoch
  severity: string;
  tags_json: string;
  payload_json: string;
}

interface ResolvedSignal {
  id: string;
  source: string;
  kind: string;
  ts: string; // ISO-8601
  severity: string;
  tags: Record<string, unknown>;
  payload: unknown;
}

function resolve(row: SignalRow): ResolvedSignal {
  let tags: Record<string, unknown> = {};
  let payload: unknown = null;
  try {
    tags = JSON.parse(row.tags_json);
  } catch {
    /* keep empty */
  }
  try {
    payload = JSON.parse(row.payload_json);
  } catch {
    payload = row.payload_json;
  }
  return {
    id: row.id,
    source: row.source,
    kind: row.kind,
    ts: new Date(row.ts).toISOString(),
    severity: row.severity,
    tags,
    payload,
  };
}

// ---------- Query helpers ----------

function clampLimit(value: unknown, fallback: number, max = 1000): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(Math.max(1, Math.floor(value)), max);
}

/**
 * Compose the WHERE / params pair for a query. Always includes the
 * project_dir scope when set so every tool transparently inherits it.
 * SQLite's JSON1 extension (`json_extract`) ships with macOS's
 * libsqlite3, so this works without any extra setup.
 */
function baseScope(): { where: string[]; params: unknown[] } {
  const where: string[] = ["1=1"];
  const params: unknown[] = [];
  if (PROJECT_SCOPE) {
    where.push("json_extract(tags_json, '$.project_dir') = ?");
    params.push(PROJECT_SCOPE);
  }
  return { where, params };
}

function querySignals(args: {
  kind?: string;
  source?: string;
  severity?: string;
  since?: string; // ISO-8601
  limit?: number;
}): ResolvedSignal[] {
  const limit = clampLimit(args.limit, 100);
  const { where, params } = baseScope();
  if (args.kind) {
    where.push("kind = ?");
    params.push(args.kind);
  }
  if (args.source) {
    where.push("source = ?");
    params.push(args.source);
  }
  if (args.severity) {
    where.push("severity = ?");
    params.push(args.severity);
  }
  if (args.since) {
    const tsMs = Date.parse(args.since);
    if (!Number.isFinite(tsMs)) {
      throw new Error(`Invalid 'since' (must parse as ISO-8601): ${args.since}`);
    }
    where.push("ts >= ?");
    params.push(tsMs);
  }
  const sql =
    `SELECT id, source, kind, ts, severity, tags_json, payload_json ` +
    `FROM signals WHERE ${where.join(" AND ")} ORDER BY ts DESC LIMIT ${limit};`;
  const rows = db.query(sql).all(...params) as SignalRow[];
  return rows.map(resolve);
}

function kindsSummary(): Array<{
  kind: string;
  count: number;
  most_recent: string;
}> {
  const { where, params } = baseScope();
  const sql =
    `SELECT kind, COUNT(*) as count, MAX(ts) as most_recent_ms ` +
    `FROM signals WHERE ${where.join(" AND ")} GROUP BY kind ORDER BY count DESC;`;
  const rows = db.query(sql).all(...params) as Array<{
    kind: string;
    count: number;
    most_recent_ms: number;
  }>;
  return rows.map((r) => ({
    kind: r.kind,
    count: r.count,
    most_recent: new Date(r.most_recent_ms).toISOString(),
  }));
}

function sourcesSummary(): Array<{
  source: string;
  count: number;
  most_recent: string;
}> {
  const { where, params } = baseScope();
  const sql =
    `SELECT source, COUNT(*) as count, MAX(ts) as most_recent_ms ` +
    `FROM signals WHERE ${where.join(" AND ")} GROUP BY source ORDER BY count DESC;`;
  const rows = db.query(sql).all(...params) as Array<{
    source: string;
    count: number;
    most_recent_ms: number;
  }>;
  return rows.map((r) => ({
    source: r.source,
    count: r.count,
    most_recent: new Date(r.most_recent_ms).toISOString(),
  }));
}

// ---------- Emit (write side) ----------

/**
 * Send one signal-emit request to the Dreamux app's listener and
 * resolve with its ack (or reject on socket / parse error).
 * One-shot connection: open, write request + newline, read ack
 * until newline, close.
 */
function emitSignalViaSocket(payload: object): Promise<{
  ok: boolean;
  id?: string;
  error?: string;
}> {
  return new Promise((resolve, reject) => {
    const sock = netConnect(EMIT_SOCKET_PATH);
    let buffer = "";
    let settled = false;

    const settle = (
      err: Error | null,
      value?: { ok: boolean; id?: string; error?: string },
    ) => {
      if (settled) return;
      settled = true;
      sock.destroy();
      if (err) reject(err);
      else if (value) resolve(value);
    };

    sock.setTimeout(5_000, () => {
      settle(new Error("emit socket timeout (Dreamux app not responding)"));
    });
    sock.on("error", (err) => {
      settle(
        new Error(
          `emit socket error: ${err.message}. ` +
            `Is the Dreamux app running, and is the socket at ${EMIT_SOCKET_PATH} reachable?`,
        ),
      );
    });
    sock.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const nlIdx = buffer.indexOf("\n");
      if (nlIdx >= 0) {
        const line = buffer.slice(0, nlIdx);
        try {
          const parsed = JSON.parse(line);
          settle(null, parsed);
        } catch (e) {
          settle(new Error(`unparseable ack from Dreamux: ${line}`));
        }
      }
    });
    sock.on("end", () => {
      if (!settled) settle(new Error("Dreamux closed connection without ack"));
    });
    sock.on("connect", () => {
      const request = JSON.stringify({ action: "emit", signal: payload }) + "\n";
      sock.write(request);
    });
  });
}

// ---------- MCP server ----------

const server = new Server(
  {
    name: "dreamux-signals",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
    },
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "signals_recent",
      description:
        "Most recent signals across the whole Dreamux substrate, newest first. " +
        "Useful for 'what's been happening on this machine recently?' agent prompts.",
      inputSchema: {
        type: "object",
        properties: {
          limit: {
            type: "number",
            description: "Max signals to return (default 50, capped at 1000).",
          },
        },
      },
    },
    {
      name: "signals_query",
      description:
        "Filter the signal log by kind / source / severity / time. All " +
        "filters AND together; omitted filters are not constraints. Returns " +
        "newest-first by `ts`. Common kinds: `terminal.line`, " +
        "`service.health`, plus whatever agents emit (`agent.note`, " +
        "`bug.report`, …).",
      inputSchema: {
        type: "object",
        properties: {
          kind: {
            type: "string",
            description: "Exact match against `Signal.kind`.",
          },
          source: {
            type: "string",
            description:
              "Exact match against `Signal.source`. Examples: " +
              "`services.main.qdrant`, `dreamux-issues`, " +
              "`flows.main.triage_critical_bug`.",
          },
          severity: {
            type: "string",
            enum: ["info", "success", "warning", "critical"],
          },
          since: {
            type: "string",
            description:
              "ISO-8601 lower bound; only signals at or after this time are returned.",
          },
          limit: {
            type: "number",
            description: "Max signals (default 100, capped at 1000).",
          },
        },
      },
    },
    {
      name: "signals_kinds_summary",
      description:
        "Inventory: every distinct `kind` in the log with row count and " +
        "most-recent timestamp. Useful for orientation — 'what's even " +
        "flowing through this Dreamux?'",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "signals_sources_summary",
      description:
        "Inventory: every distinct `source` in the log with row count " +
        "and most-recent timestamp. Tells you which manifests / services / " +
        "flows are actually emitting.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "signals_subscribe",
      description:
        "Open a live subscription to the Dreamux signal bus. Returns a " +
        "subscription id immediately; thereafter, every signal matching " +
        "the filter is pushed to your client as a " +
        "`notifications/dreamux/signal` notification (params: { subId, " +
        "signal }) until you call signals_unsubscribe(subId) or the MCP " +
        "session ends. Use this for live tailing — no polling required.",
      inputSchema: {
        type: "object",
        properties: {
          kind: { type: "string", description: "Optional kind filter." },
          source: { type: "string", description: "Optional source filter." },
        },
      },
    },
    {
      name: "signals_unsubscribe",
      description:
        "Tear down a subscription started by signals_subscribe. The " +
        "underlying connection to the Dreamux app is closed and no further " +
        "notifications fire for this subId.",
      inputSchema: {
        type: "object",
        required: ["subId"],
        properties: {
          subId: { type: "string", description: "Subscription id from signals_subscribe." },
        },
      },
    },
    {
      name: "signals_emit",
      description:
        "Drop a new signal into Dreamux's bus. The signal flows through " +
        "the same path live emitters use: persisted to the SQLite log, " +
        "republished to in-process subscribers (SignalsView, FlowEngine, " +
        "manifest runners' listeners). A flow watching the kind you emit " +
        "fires immediately. Use this to record findings, agent decisions, " +
        "bug reports, second-order signals — anything you want the rest " +
        "of the Dreamux substrate (and any downstream agent or tab) to see.",
      inputSchema: {
        type: "object",
        required: ["kind"],
        properties: {
          kind: {
            type: "string",
            description:
              "Required. The `Signal.kind` to emit. Common patterns: " +
              "`bug.report`, `agent.task`, `agent.note`, `agent.completed`, " +
              "`finding.security`. Custom flows pick the convention.",
          },
          source: {
            type: "string",
            description:
              "Optional. Identifies who emitted. Defaults to `external`. " +
              "Recommended pattern: `external.<your-agent-name>` (e.g. " +
              "`external.claude-code`).",
          },
          severity: {
            type: "string",
            enum: ["info", "success", "warning", "critical"],
            description: "Optional. Defaults to info.",
          },
          tags: {
            type: "object",
            description:
              "Optional string→string map. Used by tabs to render and " +
              "by flows to filter. Recommended keys when relevant: " +
              "`title`, `url`, `project_dir`, `severity`, `state`, `column` " +
              "(for board.item kinds).",
            additionalProperties: { type: "string" },
          },
          payload: {
            description:
              "Optional. Arbitrary JSON. Gets stored verbatim and " +
              "available to flows / consumers via the `payload` field on " +
              "each Signal envelope.",
          },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const argRecord: Record<string, unknown> = (args ?? {}) as Record<
    string,
    unknown
  >;

  function asString(key: string): string | undefined {
    const v = argRecord[key];
    return typeof v === "string" && v.length > 0 ? v : undefined;
  }
  function asNumber(key: string): number | undefined {
    const v = argRecord[key];
    return typeof v === "number" && Number.isFinite(v) ? v : undefined;
  }

  try {
    switch (name) {
      case "signals_recent": {
        const limit = clampLimit(asNumber("limit"), 50);
        const rows = querySignals({ limit });
        return jsonResult(rows);
      }
      case "signals_query": {
        const rows = querySignals({
          kind: asString("kind"),
          source: asString("source"),
          severity: asString("severity"),
          since: asString("since"),
          limit: asNumber("limit"),
        });
        return jsonResult(rows);
      }
      case "signals_kinds_summary":
        return jsonResult(kindsSummary());
      case "signals_sources_summary":
        return jsonResult(sourcesSummary());
      case "signals_subscribe": {
        const kind = asString("kind");
        const source = asString("source");
        const subId = openPushSubscription({
          kind,
          source,
          projectDir: PROJECT_SCOPE,
        });
        return jsonResult({
          subId,
          subscribed: true,
          notification_method: "notifications/dreamux/signal",
        });
      }
      case "signals_unsubscribe": {
        const subId = asString("subId");
        if (!subId) return errorResult("signals_unsubscribe: 'subId' is required");
        const ok = closePushSubscription(subId);
        return jsonResult({ subId, closed: ok });
      }
      case "signals_emit": {
        const kind = asString("kind");
        if (!kind) {
          return errorResult("signals_emit: 'kind' is required");
        }
        const tagsArg = argRecord["tags"];
        const tags: Record<string, string> =
          typeof tagsArg === "object" && tagsArg !== null
            ? { ...(tagsArg as Record<string, string>) }
            : {};
        // Auto-tag project_dir so subscribe filters / project-scoped
        // tabs / flows pick up the emit. Mirrors what manifest /
        // services / checks emitters already do — without this
        // external agent emits would be invisible to project-scoped
        // consumers. Caller-supplied tag wins if set explicitly.
        if (PROJECT_SCOPE && !tags.project_dir) {
          tags.project_dir = PROJECT_SCOPE;
        }
        const signal: Record<string, unknown> = { kind };
        if (asString("source")) signal.source = asString("source");
        if (asString("severity")) signal.severity = asString("severity");
        if (Object.keys(tags).length > 0) signal.tags = tags;
        if (argRecord["payload"] !== undefined) {
          signal.payload = argRecord["payload"];
        }
        const ack = await emitSignalViaSocket(signal);
        return jsonResult(ack);
      }
      default:
        return errorResult(`unknown tool: ${name}`);
    }
  } catch (err) {
    return errorResult(err instanceof Error ? err.message : String(err));
  }
});

/**
 * Active push subscriptions, keyed by the subId we hand back to
 * the MCP client. Each entry owns a long-lived TCP connection to
 * the Dreamux app's emit socket; envelopes arriving on that socket
 * are forwarded to the client via `server.notification(...)`.
 *
 * Lives at module scope so a single MCP server process can hold
 * many concurrent subscriptions for one client (e.g. a
 * release-watcher agent that subscribes to both `release.event`
 * and `bug.report` simultaneously).
 */
const activeSubscriptions = new Map<
  string,
  { socket: ReturnType<typeof netConnect> }
>();

/**
 * Open a long-running connection to the Dreamux app's emit socket
 * with `action: "subscribe"` and start forwarding envelopes to
 * the MCP client as `notifications/dreamux/signal` notifications.
 * Returns the synthesized subId immediately so the caller can
 * cross-reference incoming notifications.
 */
function openPushSubscription(args: {
  kind?: string;
  source?: string;
  projectDir: string | null;
}): string {
  const subId = `sub-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const sock = netConnect(EMIT_SOCKET_PATH);
  let buffer = "";

  sock.on("error", (err) => {
    process.stderr.write(
      `dreamux-signals-mcp: subscription ${subId} socket error: ${err.message}\n`,
    );
    activeSubscriptions.delete(subId);
  });
  sock.on("close", () => {
    activeSubscriptions.delete(subId);
  });
  sock.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    while (true) {
      const nlIdx = buffer.indexOf("\n");
      if (nlIdx < 0) break;
      const line = buffer.slice(0, nlIdx);
      buffer = buffer.slice(nlIdx + 1);
      if (!line) continue;
      try {
        const parsed = JSON.parse(line);
        if (parsed.subscribed === true) continue; // initial ack
        if (parsed.closed === true) {
          sock.destroy();
          activeSubscriptions.delete(subId);
          return;
        }
        if (parsed.signal) {
          // Push the envelope to the MCP client as a notification.
          // Errors here (client gone, transport issue) shouldn't
          // crash the whole server — log + continue and let the
          // socket close handler clean up the subscription if the
          // peer is actually gone.
          server
            .notification({
              method: "notifications/dreamux/signal",
              params: { subId, signal: parsed.signal },
            })
            .catch((err) => {
              process.stderr.write(
                `dreamux-signals-mcp: notification dispatch failed for ${subId}: ${err}\n`,
              );
            });
        }
      } catch {
        /* ignore unparseable line */
      }
    }
  });
  sock.on("connect", () => {
    const filter: Record<string, string> = {};
    if (args.kind) filter.kind = args.kind;
    if (args.source) filter.source = args.source;
    if (args.projectDir) filter.project_dir = args.projectDir;
    // No max_events / no timeout: we want this to live as long as
    // the MCP session does. The Dreamux app's subscribe handler
    // honors max_events = Int.max (no cap) and timeout = 0
    // (block forever) for that combination.
    const request =
      JSON.stringify({
        action: "subscribe",
        filter,
        max_events: 0,
        timeout_seconds: 0,
      }) + "\n";
    sock.write(request);
  });

  activeSubscriptions.set(subId, { socket: sock });
  return subId;
}

function closePushSubscription(subId: string): boolean {
  const entry = activeSubscriptions.get(subId);
  if (!entry) return false;
  entry.socket.destroy();
  activeSubscriptions.delete(subId);
  return true;
}

// Tear down all live subscriptions when the MCP process is winding
// down — closes the dangling sockets gracefully on the Dreamux side.
function shutdownAllSubscriptions() {
  for (const [, entry] of activeSubscriptions) {
    entry.socket.destroy();
  }
  activeSubscriptions.clear();
}
process.on("SIGINT", () => {
  shutdownAllSubscriptions();
  process.exit(0);
});
process.on("SIGTERM", () => {
  shutdownAllSubscriptions();
  process.exit(0);
});

function jsonResult(value: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(value, null, 2),
      },
    ],
  };
}

function errorResult(message: string) {
  return {
    isError: true,
    content: [
      {
        type: "text" as const,
        text: message,
      },
    ],
  };
}

const transport = new StdioServerTransport();
await server.connect(transport);
process.stderr.write("dreamux-signals-mcp: ready over stdio\n");
