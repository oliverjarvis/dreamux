import { ReactFlowProvider, useReactFlow } from '@xyflow/react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { Board } from './Board'
import { Bridge, webkitTransport } from './bridge'
import './styles.css'
import { applyTheme } from './theme'
import type {
  DebugState, FocusLaneRequest, RestoreLayout, Snapshot, Theme, TidyUpRequest, XY,
} from './types'

/** Expansion is EXPLICIT state, never a side effect of zoom: each expanded
 *  lane subscribes a transcript tail, and zooming past ten lanes must not
 *  open ten tails. Capped at three, LRU-collapsing the oldest. */
const EXPANSION_CAP = 3

const HANDLER = 'dreamuxFlows'
const bridge = new Bridge()

interface Facade {
  render(json: string): void
  applyTheme(json: string): void
  focusLane(json: string): void
  restoreLayout(json: string): void
  tidyUp(json: string): void
  debugState(): string
}

declare global {
  interface Window { dreamuxFlows: Facade }
}

const emptySnapshot: Snapshot = { schemaVersion: 1, aggregates: { running: 0, needsYou: 0 }, lanes: [] }

/** Handlers registered by <App/> once mounted; the façade is installed
 *  synchronously at load so a native push can never arrive before it. */
const handlers: Partial<Facade> = {}

function parse<T>(json: string, fallback: T): T {
  try {
    return JSON.parse(json) as T
  } catch {
    return fallback
  }
}

function App(): JSX.Element {
  const [snapshot, setSnapshot] = useState<Snapshot>(emptySnapshot)
  const [expanded, setExpanded] = useState<string[]>([])
  const [lanePositions, setLanePositions] = useState<Record<string, XY>>({})
  const [nodePositions, setNodePositions] = useState<Record<string, Record<string, XY>>>({})
  const [focusRequest, setFocusRequest] = useState<{ laneID: string; token: number } | null>(null)
  const { setViewport, getNodes, getViewport } = useReactFlow()

  /** Expansion drives the lazy transcript tail: `setLaneExpanded(true)`
   *  begins a tail, `false` releases it, and an LRU collapse releases the
   *  oldest one the same way. */
  const setLaneExpanded = useCallback((laneID: string, next: boolean) => {
    setExpanded((current) => {
      if (next) {
        if (current.includes(laneID)) return current
        const grown = [...current, laneID]
        const evicted = grown.slice(0, Math.max(0, grown.length - EXPANSION_CAP))
        for (const id of evicted) {
          bridge.send('setLaneExpanded', { laneID: id, expanded: false })
        }
        bridge.send('setLaneExpanded', { laneID, expanded: true })
        return grown.slice(-EXPANSION_CAP)
      }
      if (!current.includes(laneID)) return current
      bridge.send('setLaneExpanded', { laneID, expanded: false })
      return current.filter((id) => id !== laneID)
    })
  }, [])

  const toggleLane = useCallback((laneID: string) => {
    setExpanded((current) => {
      const next = !current.includes(laneID)
      // Defer the side-effecting path so this stays a pure updater.
      queueMicrotask(() => setLaneExpanded(laneID, next))
      return current
    })
  }, [setLaneExpanded])

  const onLayoutError = useCallback((message: string) => {
    bridge.send('jsError', { message })
  }, [])

  useEffect(() => {
    handlers.render = (json) => setSnapshot(parse<Snapshot>(json, emptySnapshot))

    handlers.applyTheme = (json) =>
      applyTheme(parse<Theme>(json, { vars: {}, reduceMotion: false }))

    handlers.focusLane = (json) => {
      const request = parse<FocusLaneRequest>(json, { laneID: null, expand: true })
      if (request.laneID == null) {
        // The `laneID: null` form collapses whatever is expanded.
        setExpanded((current) => {
          for (const id of current) bridge.send('setLaneExpanded', { laneID: id, expanded: false })
          return []
        })
        return
      }
      if (request.expand) setLaneExpanded(request.laneID, true)
      setFocusRequest({ laneID: request.laneID, token: Date.now() })
    }

    handlers.restoreLayout = (json) => {
      const saved = parse<RestoreLayout>(json, {
        lanePositions: {}, nodePositions: {}, expandedLaneIDs: [], viewport: null,
      })
      setLanePositions(saved.lanePositions ?? {})
      setNodePositions(saved.nodePositions ?? {})
      const restored = (saved.expandedLaneIDs ?? []).slice(-EXPANSION_CAP)
      setExpanded(restored)
      // Each surviving entry subscribes its lazy tail exactly as a click would.
      for (const id of restored) bridge.send('setLaneExpanded', { laneID: id, expanded: true })
      if (saved.viewport) setViewport(saved.viewport)
    }

    handlers.tidyUp = (json) => {
      const request = parse<TidyUpRequest>(json, {})
      if (request.laneID) {
        setLanePositions((current) => {
          const next = { ...current }
          delete next[request.laneID!]
          return next
        })
        setNodePositions((current) => {
          const next = { ...current }
          delete next[request.laneID!]
          return next
        })
      } else {
        setLanePositions({})
        setNodePositions({})
      }
    }
  }, [setLaneExpanded, setViewport])

  /// Read straight off React Flow rather than off our own props: this is
  /// the e2e harness's proof that the canvas DREW the board, so reporting
  /// the inputs we were handed would assert nothing. `lanePositions` in
  /// particular holds only RESTORED positions — an auto-laid-out lane has
  /// no entry there, but it does have a rendered one.
  const debug = useMemo<() => DebugState>(() => () => {
    const nodes = getNodes()
    const lanePositions: Record<string, XY> = {}
    for (const node of nodes) {
      if (node.type !== 'lane') continue
      const laneID = (node.data as { laneID?: string }).laneID
      if (laneID) lanePositions[laneID] = { x: node.position.x, y: node.position.y }
    }
    return {
      mounted: true,
      nodeIDs: nodes.map((node) => node.id),
      expanded,
      lanePositions,
      zoom: getViewport().zoom,
    }
  }, [getNodes, getViewport, expanded])

  useEffect(() => {
    handlers.debugState = () => JSON.stringify(debug())
  }, [debug])

  return (
    <Board
      snapshot={snapshot}
      expanded={expanded}
      lanePositions={lanePositions}
      nodePositions={nodePositions}
      bridge={bridge}
      onToggleLane={toggleLane}
      focusRequest={focusRequest}
      onLayoutError={onLayoutError}
    />
  )
}

// --- Install the façade and error forwarding BEFORE React mounts, so a
// --- push or a crash during mount is never lost.
const emptyDebug: DebugState = {
  mounted: false, nodeIDs: [], expanded: [], lanePositions: {}, zoom: 1,
}

window.dreamuxFlows = {
  render: (json) => handlers.render?.(json),
  applyTheme: (json) => handlers.applyTheme?.(json),
  focusLane: (json) => handlers.focusLane?.(json),
  restoreLayout: (json) => handlers.restoreLayout?.(json),
  tidyUp: (json) => handlers.tidyUp?.(json),
  debugState: () => handlers.debugState?.() ?? JSON.stringify(emptyDebug),
}

window.onerror = (message, source, line) =>
  bridge.send('jsError', { message: `${String(message)} (${source ?? '?'}:${line ?? 0})` })
window.onunhandledrejection = (event) =>
  bridge.send('jsError', { message: String(event.reason) })
window.addEventListener('pagehide', () => bridge.flush())

bridge.attach(webkitTransport(HANDLER))

createRoot(document.getElementById('root')!).render(
  <ReactFlowProvider>
    <App />
  </ReactFlowProvider>,
)

bridge.send('ready')
