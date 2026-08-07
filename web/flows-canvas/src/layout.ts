import dagre from '@dagrejs/dagre'
import type { XY } from './types'

/** Horizontal gap between sibling lanes in a rank (dagre `nodesep`). */
export const LANE_GAP_X = 48
/** Vertical gap between lane ranks (dagre `ranksep`). */
export const LANE_GAP_Y = 64
export const NODE_GAP_X = 30
export const NODE_GAP_Y = 48
/** Padding around the union of a phase run's task nodes. */
export const BAND_PADDING = 14

export interface LaneBox {
  id: string
  /** Measured by React Flow — in HTML a node's size is only knowable
   *  once the DOM has measured it, which is why layout lives here. */
  width: number
  height: number
  dependsOn: string[]
  /** Lanes with no plan (ad-hoc and scheduled sessions) are rootless and
   *  pack into a trailing column rather than joining the DAG. */
  hasPlan: boolean
}

export interface LaneLayout {
  /** id → TOP-LEFT position. */
  positions: Record<string, XY>
  size: { width: number; height: number }
  /** True when dagre was skipped for the degraded column packing. */
  fallback: boolean
}

export interface TaskBox {
  id: string
  width: number
  height: number
  group?: string | null
}

export interface TaskEdge {
  from: string
  to: string
}

export interface Band {
  title: string
  x: number
  y: number
  width: number
  height: number
}

export interface InternalLayout {
  /** id → PARENT-RELATIVE top-left position. */
  positions: Record<string, XY>
  bands: Band[]
  size: { width: number; height: number }
  fallback: boolean
}

/** Self-edges are excluded from dagre (a zero-length edge degenerates the
 *  ranking) and drawn by the custom self-arc edge instead. */
export function selfLoops(edges: TaskEdge[]): TaskEdge[] {
  return edges.filter((edge) => edge.from === edge.to)
}

/** Iterative DFS with a colour marking. Self-loops do not count — they are
 *  drawn separately and never reach dagre. */
export function hasCycle(ids: string[], edges: TaskEdge[]): boolean {
  const out = new Map<string, string[]>()
  for (const id of ids) out.set(id, [])
  for (const edge of edges) {
    if (edge.from === edge.to) continue
    if (!out.has(edge.from) || !out.has(edge.to)) continue
    out.get(edge.from)!.push(edge.to)
  }
  const state = new Map<string, 0 | 1 | 2>()   // 0 unseen, 1 on stack, 2 done
  for (const id of ids) state.set(id, 0)

  for (const root of ids) {
    if (state.get(root) !== 0) continue
    const stack: Array<{ id: string; index: number }> = [{ id: root, index: 0 }]
    state.set(root, 1)
    while (stack.length > 0) {
      const frame = stack[stack.length - 1]
      const neighbours = out.get(frame.id)!
      if (frame.index >= neighbours.length) {
        state.set(frame.id, 2)
        stack.pop()
        continue
      }
      const next = neighbours[frame.index++]
      const colour = state.get(next)
      if (colour === 1) return true
      if (colour === 0) {
        state.set(next, 1)
        stack.push({ id: next, index: 0 })
      }
    }
  }
  return false
}

/** A readable degradation when the dependency data is cyclic or dagre
 *  throws: one column, in input order. Matches `FlowLayoutEngine`'s
 *  existing "degrade rather than crash" stance. */
function columnPack(
  boxes: Array<{ id: string; width: number; height: number }>,
  gapY: number,
): { positions: Record<string, XY>; size: { width: number; height: number } } {
  const positions: Record<string, XY> = {}
  let y = 0
  let width = 0
  for (const box of boxes) {
    positions[box.id] = { x: 0, y }
    y += box.height + gapY
    width = Math.max(width, box.width)
  }
  return {
    positions,
    size: { width, height: Math.max(0, y - gapY) },
  }
}

function measure(
  positions: Record<string, XY>,
  boxes: Array<{ id: string; width: number; height: number }>,
): { width: number; height: number } {
  let width = 0
  let height = 0
  for (const box of boxes) {
    const point = positions[box.id]
    if (!point) continue
    width = Math.max(width, point.x + box.width)
    height = Math.max(height, point.y + box.height)
  }
  return { width, height }
}

/** dagre over `boxes`/`edges`, top-to-bottom, returning TOP-LEFT points.
 *  Throws are the caller's to catch. */
function dagreLayout(
  boxes: Array<{ id: string; width: number; height: number }>,
  edges: TaskEdge[],
  nodesep: number,
  ranksep: number,
): Record<string, XY> {
  const graph = new dagre.graphlib.Graph()
  graph.setGraph({ rankdir: 'TB', nodesep, ranksep, marginx: 0, marginy: 0 })
  graph.setDefaultEdgeLabel(() => ({}))
  const present = new Set(boxes.map((box) => box.id))
  for (const box of boxes) {
    graph.setNode(box.id, { width: box.width, height: box.height })
  }
  for (const edge of edges) {
    if (edge.from === edge.to) continue
    if (!present.has(edge.from) || !present.has(edge.to)) continue
    graph.setEdge(edge.from, edge.to)
  }
  dagre.layout(graph)

  const positions: Record<string, XY> = {}
  for (const box of boxes) {
    const laid = graph.node(box.id)
    if (!laid) continue
    // dagre reports CENTRES; React Flow positions by TOP-LEFT.
    positions[box.id] = { x: laid.x - box.width / 2, y: laid.y - box.height / 2 }
  }
  return normaliseToOrigin(positions, boxes)
}

/** Shift so the tightest bounding box starts at (0, 0) — lane internals
 *  must be parent-relative, and a board that starts at the origin makes
 *  saved positions comparable across relayouts. */
function normaliseToOrigin(
  positions: Record<string, XY>,
  boxes: Array<{ id: string; width: number; height: number }>,
): Record<string, XY> {
  const points = boxes.map((box) => positions[box.id]).filter(Boolean) as XY[]
  if (points.length === 0) return positions
  const minX = Math.min(...points.map((p) => p.x))
  const minY = Math.min(...points.map((p) => p.y))
  const shifted: Record<string, XY> = {}
  for (const box of boxes) {
    const point = positions[box.id]
    if (!point) continue
    shifted[box.id] = { x: point.x - minX, y: point.y - minY }
  }
  return shifted
}

/**
 * Lane placement: dagre over the lane graph with `dependsOn` as edges.
 * Lanes with no plan are rootless — they pack into a trailing column to
 * the right of the DAG rather than joining it. Saved positions win over
 * computed ones, per id; a lane that appeared after a save is auto-placed.
 */
export function layoutLanes(
  lanes: LaneBox[],
  saved: Record<string, XY> = {},
): LaneLayout {
  if (lanes.length === 0) {
    return { positions: {}, size: { width: 0, height: 0 }, fallback: false }
  }

  const dagLanes = lanes.filter((laneBox) => laneBox.hasPlan)
  const rootless = lanes.filter((laneBox) => !laneBox.hasPlan)
  const edges: TaskEdge[] = []
  const dagIDs = new Set(dagLanes.map((laneBox) => laneBox.id))
  for (const laneBox of dagLanes) {
    for (const blocker of laneBox.dependsOn) {
      if (dagIDs.has(blocker)) edges.push({ from: blocker, to: laneBox.id })
    }
  }

  let positions: Record<string, XY>
  let fallback = false

  if (hasCycle(dagLanes.map((l) => l.id), edges)) {
    fallback = true
    positions = columnPack(lanes, LANE_GAP_Y).positions
  } else {
    try {
      positions = dagreLayout(dagLanes, edges, LANE_GAP_X, LANE_GAP_Y)
      // Rootless lanes stack in a column just right of the DAG.
      const dagRight = dagLanes.reduce((right, laneBox) => {
        const point = positions[laneBox.id]
        return point ? Math.max(right, point.x + laneBox.width) : right
      }, 0)
      const columnX = dagLanes.length === 0 ? 0 : dagRight + LANE_GAP_X
      let y = 0
      for (const laneBox of rootless) {
        positions[laneBox.id] = { x: columnX, y }
        y += laneBox.height + LANE_GAP_Y
      }
    } catch {
      fallback = true
      positions = columnPack(lanes, LANE_GAP_Y).positions
    }
  }

  // Saved positions win, per id.
  for (const laneBox of lanes) {
    const savedPoint = saved[laneBox.id]
    if (savedPoint) positions[laneBox.id] = { x: savedPoint.x, y: savedPoint.y }
  }

  return { positions, size: measure(positions, lanes), fallback }
}

/**
 * One expanded lane's internals: dagre over its own nodes and edges,
 * emitted as PARENT-RELATIVE coordinates for React Flow group children.
 * Phase bands (maximal runs of a shared `group`, in input order) come back
 * as rects to render as non-interactive nested group nodes.
 */
export function layoutLaneInternals(
  nodes: TaskBox[],
  edges: TaskEdge[],
  saved: Record<string, XY> = {},
): InternalLayout {
  if (nodes.length === 0) {
    return { positions: {}, bands: [], size: { width: 0, height: 0 }, fallback: false }
  }

  let positions: Record<string, XY>
  let fallback = false

  if (hasCycle(nodes.map((node) => node.id), edges)) {
    fallback = true
    positions = columnPack(nodes, NODE_GAP_Y).positions
  } else {
    try {
      positions = dagreLayout(nodes, edges, NODE_GAP_X, NODE_GAP_Y)
    } catch {
      fallback = true
      positions = columnPack(nodes, NODE_GAP_Y).positions
    }
  }

  for (const node of nodes) {
    const savedPoint = saved[node.id]
    if (savedPoint) positions[node.id] = { x: savedPoint.x, y: savedPoint.y }
  }

  return {
    positions,
    bands: phaseBands(nodes, positions),
    size: measure(positions, nodes),
    fallback,
  }
}

/**
 * Maximal runs of nodes sharing a non-empty `group`, in input order (the
 * order `PlanFlowBuilder` appended them, which is also their rank order).
 * A `group`-less node — or one with no laid-out position — breaks the
 * current run without starting a new one. Mirrors the rule the deleted
 * `FlowDetailView.phaseBands` used.
 */
function phaseBands(nodes: TaskBox[], positions: Record<string, XY>): Band[] {
  interface Run { title: string; minX: number; minY: number; maxX: number; maxY: number }
  const runs: Run[] = []
  let currentGroup: string | null = null

  for (const node of nodes) {
    const group = node.group ?? null
    const point = positions[node.id]
    if (!group || !point) {
      currentGroup = null
      continue
    }
    const left = point.x
    const top = point.y
    const right = point.x + node.width
    const bottom = point.y + node.height
    const last = runs[runs.length - 1]
    if (group === currentGroup && last) {
      last.minX = Math.min(last.minX, left)
      last.minY = Math.min(last.minY, top)
      last.maxX = Math.max(last.maxX, right)
      last.maxY = Math.max(last.maxY, bottom)
    } else {
      currentGroup = group
      runs.push({ title: group, minX: left, minY: top, maxX: right, maxY: bottom })
    }
  }

  return runs.map((run) => ({
    title: run.title,
    x: run.minX - BAND_PADDING,
    y: run.minY - BAND_PADDING,
    width: run.maxX - run.minX + BAND_PADDING * 2,
    height: run.maxY - run.minY + BAND_PADDING * 2,
  }))
}
