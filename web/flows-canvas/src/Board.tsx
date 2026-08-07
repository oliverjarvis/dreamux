import {
  Controls,
  MiniMap,
  ReactFlow,
  useNodesState,
  useEdgesState,
  useReactFlow,
  useStore,
  type Edge,
  type Node,
  type NodeChange,
  type Viewport,
} from '@xyflow/react'
import { useCallback, useEffect, useMemo, useRef } from 'react'
import type { Bridge } from './bridge'
import {
  LANE_GAP_Y,
  layoutLaneInternals,
  layoutLanes,
  selfLoops,
  type LaneBox,
  type TaskBox,
  type TaskEdge,
} from './layout'
import { GateNode } from './nodes/GateNode'
import { LaneNode } from './nodes/LaneNode'
import { PhaseBand } from './nodes/PhaseBand'
import { SelfLoopEdge } from './nodes/SelfLoopEdge'
import { TaskNode } from './nodes/TaskNode'
import { prefersReducedMotion } from './theme'
import type { Lane, Snapshot, XY } from './types'

const nodeTypes = { lane: LaneNode, task: TaskNode, gate: GateNode, band: PhaseBand }
const edgeTypes = { selfLoop: SelfLoopEdge }

/** Below this scale an expanded lane's children render as unlabelled dots
 *  and edge labels drop out. */
export const DETAIL_ZOOM = 0.5

const COLLAPSED_LANE = { width: 280, height: 92 }
const TASK_SIZE = { width: 150, height: 44 }
const LANE_PADDING = { x: 20, top: 100, bottom: 20 }

export const laneNodeID = (laneID: string) => `lane:${laneID}`
export const taskNodeID = (laneID: string, nodeID: string) => `node:${laneID}:${nodeID}`
export const bandNodeID = (laneID: string, index: number) => `band:${laneID}:${index}`

export interface BoardProps {
  snapshot: Snapshot
  expanded: string[]
  lanePositions: Record<string, XY>
  nodePositions: Record<string, Record<string, XY>>
  bridge: Bridge
  onToggleLane(laneID: string): void
  /** Non-null while a focusLane request is outstanding. */
  focusRequest: { laneID: string; token: number } | null
  onLayoutError(message: string): void
}

export function Board(props: BoardProps): JSX.Element {
  const {
    snapshot, expanded, lanePositions, nodePositions,
    bridge, onToggleLane, focusRequest, onLayoutError,
  } = props

  const zoom = useStore((state) => state.transform[2])
  const detailed = zoom >= DETAIL_ZOOM
  const { fitView, getNodes } = useReactFlow()
  const expandedSet = useMemo(() => new Set(expanded), [expanded])

  const built = useMemo(
    () => buildGraph(snapshot, expandedSet, lanePositions, nodePositions, detailed, onToggleLane),
    [snapshot, expandedSet, lanePositions, nodePositions, detailed, onToggleLane],
  )

  const [nodes, setNodes, onNodesChange] = useNodesState<Node>(built.nodes)
  const [edges, setEdges] = useEdgesState<Edge>(built.edges)

  // No diffing on the wire: React Flow reconciles by node id.
  useEffect(() => {
    setNodes(built.nodes)
    setEdges(built.edges)
    if (built.error) onLayoutError(built.error)
  }, [built, setNodes, setEdges, onLayoutError])

  // focusLane: expand-and-fit one lane.
  const lastFocus = useRef(0)
  useEffect(() => {
    if (!focusRequest || focusRequest.token === lastFocus.current) return
    lastFocus.current = focusRequest.token
    const target = getNodes().find((node) => node.id === laneNodeID(focusRequest.laneID))
    if (!target) return
    void fitView({
      nodes: [{ id: target.id }],
      duration: prefersReducedMotion() ? 0 : 250,
      padding: 0.3,
    })
  }, [focusRequest, fitView, getNodes])

  const handleNodesChange = useCallback((changes: NodeChange<Node>[]) => {
    onNodesChange(changes)
  }, [onNodesChange])

  // Dragging repositions; it never rewires. Positions are saved per lane
  // (or as lane boxes) on drag end, debounced in the bridge.
  const handleNodeDragStop = useCallback(() => {
    const current = getNodes()
    const laneBoxes: Array<{ id: string; x: number; y: number }> = []
    const perLane = new Map<string, Array<{ id: string; x: number; y: number }>>()

    for (const node of current) {
      if (node.type === 'lane') {
        const laneID = (node.data as { laneID: string }).laneID
        laneBoxes.push({ id: laneID, x: node.position.x, y: node.position.y })
      } else if (node.type === 'task' || node.type === 'gate') {
        const meta = node.data as { laneID: string; nodeID: string }
        const bucket = perLane.get(meta.laneID) ?? []
        bucket.push({ id: meta.nodeID, x: node.position.x, y: node.position.y })
        perLane.set(meta.laneID, bucket)
      }
    }

    bridge.sendDebounced('positions:lanes', 'saveNodePositions', { positions: laneBoxes })
    for (const [laneID, positions] of perLane) {
      bridge.sendDebounced(`positions:${laneID}`, 'saveNodePositions', { laneID, positions })
    }
  }, [bridge, getNodes])

  const handleMoveEnd = useCallback((_event: unknown, viewport: Viewport) => {
    bridge.sendDebounced('viewport', 'saveViewport',
      { x: viewport.x, y: viewport.y, zoom: viewport.zoom })
  }, [bridge])

  const handleNodeClick = useCallback((_event: unknown, node: Node) => {
    if (node.type === 'lane') {
      bridge.send('selectNode', { laneID: (node.data as { laneID: string }).laneID })
      return
    }
    if (node.type === 'task' || node.type === 'gate') {
      const meta = node.data as { laneID: string; nodeID: string }
      bridge.send('selectNode', { laneID: meta.laneID, nodeID: meta.nodeID })
    }
  }, [bridge])

  const handleNodeDoubleClick = useCallback((_event: unknown, node: Node) => {
    if (node.type !== 'lane') return
    onToggleLane((node.data as { laneID: string }).laneID)
  }, [onToggleLane])

  return (
    <ReactFlow
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      onNodesChange={handleNodesChange}
      onNodeDragStop={handleNodeDragStop}
      onNodeClick={handleNodeClick}
      onNodeDoubleClick={handleNodeDoubleClick}
      onMoveEnd={handleMoveEnd}
      onPaneClick={() => bridge.send('selectNode', { laneID: '' })}
      minZoom={0.15}
      maxZoom={2}
      nodesConnectable={false}
      /* Dragging repositions; it never rewires. */
      edgesFocusable={false}
      elementsSelectable
      fitView
      /* No <Background/>: the canvas paints on the app surface. */
    >
      <MiniMap pannable zoomable nodeStrokeWidth={2} />
      <Controls showInteractive={false} />
    </ReactFlow>
  )
}

interface BuiltGraph {
  nodes: Node[]
  edges: Edge[]
  error: string | null
}

/** Snapshot + expansion → React Flow nodes/edges. Pure apart from the
 *  toggle callback it threads onto lane nodes. */
function buildGraph(
  snapshot: Snapshot,
  expanded: Set<string>,
  savedLanes: Record<string, XY>,
  savedNodes: Record<string, Record<string, XY>>,
  detailed: boolean,
  onToggle: (laneID: string) => void,
): BuiltGraph {
  const nodes: Node[] = []
  const edges: Edge[] = []
  let error: string | null = null

  // Per-lane internals first: an expanded lane's box must be big enough
  // to hold them, and the lane graph is laid out from measured boxes.
  const internals = new Map<string, ReturnType<typeof layoutLaneInternals>>()
  for (const lane of snapshot.lanes) {
    if (!expanded.has(lane.id)) continue
    const boxes: TaskBox[] = lane.nodes.map((node) => ({
      id: node.id,
      width: TASK_SIZE.width,
      height: TASK_SIZE.height,
      group: node.group ?? null,
    }))
    const taskEdges: TaskEdge[] = lane.edges.map((edge) => ({ from: edge.from, to: edge.to }))
    const layout = layoutLaneInternals(boxes, taskEdges, savedNodes[lane.id] ?? {})
    if (layout.fallback) {
      error = `Lane "${lane.title}" has cyclic task data — fell back to a column layout.`
    }
    internals.set(lane.id, layout)
  }

  const laneBoxes: LaneBox[] = snapshot.lanes.map((lane) => {
    const internal = internals.get(lane.id)
    return {
      id: lane.id,
      width: internal
        ? Math.max(COLLAPSED_LANE.width, internal.size.width + LANE_PADDING.x * 2)
        : COLLAPSED_LANE.width,
      height: internal
        ? LANE_PADDING.top + internal.size.height + LANE_PADDING.bottom
        : COLLAPSED_LANE.height,
      dependsOn: lane.dependsOn,
      hasPlan: lane.planPath != null,
    }
  })

  const laneLayout = layoutLanes(laneBoxes, savedLanes)
  if (laneLayout.fallback) {
    error = 'The plan-dependency graph is cyclic — lanes fell back to a column layout.'
  }

  for (const lane of snapshot.lanes) {
    const box = laneBoxes.find((candidate) => candidate.id === lane.id)!
    const position = laneLayout.positions[lane.id] ?? { x: 0, y: 0 }
    nodes.push({
      id: laneNodeID(lane.id),
      type: 'lane',
      position,
      style: { width: box.width, height: box.height },
      data: laneData(lane, expanded.has(lane.id), onToggle),
    })

    for (const blocker of lane.dependsOn) {
      edges.push({
        id: `dep:${blocker}->${lane.id}`,
        source: laneNodeID(blocker),
        target: laneNodeID(lane.id),
        animated: false,
      })
    }

    const internal = internals.get(lane.id)
    if (!internal) continue

    // Phase bands sit under the tasks and never hit-test.
    internal.bands.forEach((band, index) => {
      nodes.push({
        id: bandNodeID(lane.id, index),
        type: 'band',
        parentId: laneNodeID(lane.id),
        extent: 'parent',
        draggable: false,
        selectable: false,
        position: { x: band.x + LANE_PADDING.x, y: band.y + LANE_PADDING.top },
        style: { width: band.width, height: band.height, zIndex: -1 },
        data: { title: band.title },
      })
    })

    const statusByNodeID = new Map(lane.nodes.map((node) => [node.id, node.status]))

    for (const node of lane.nodes) {
      const point = internal.positions[node.id]
      if (!point) continue
      nodes.push({
        id: taskNodeID(lane.id, node.id),
        type: node.kind === 'gate' ? 'gate' : 'task',
        parentId: laneNodeID(lane.id),
        extent: 'parent',
        position: { x: point.x + LANE_PADDING.x, y: point.y + LANE_PADDING.top },
        data: {
          laneID: lane.id,
          nodeID: node.id,
          label: node.label,
          status: node.status,
          multiplicity: node.multiplicity ?? null,
          detailed,
        },
      })
    }

    const loops = new Set(selfLoops(
      lane.edges.map((edge) => ({ from: edge.from, to: edge.to })),
    ).map((edge) => edge.from))

    for (const edge of lane.edges) {
      const isSelfLoop = edge.from === edge.to
      if (!isSelfLoop && (!internal.positions[edge.from] || !internal.positions[edge.to])) continue
      if (isSelfLoop && !loops.has(edge.from)) continue
      // Animate only edges ENTERING a running node, and only when motion
      // is allowed.
      const animated = !prefersReducedMotion() && statusByNodeID.get(edge.to) === 'running'
      edges.push({
        id: `e:${lane.id}:${edge.from}->${edge.to}:${edge.kind}`,
        source: taskNodeID(lane.id, edge.from),
        target: taskNodeID(lane.id, edge.to),
        type: isSelfLoop ? 'selfLoop' : undefined,
        animated,
        label: detailed && edge.kind === 'loop' && !isSelfLoop
          ? `↺ ×${edge.iterations ?? 0}` : undefined,
        data: { iterations: edge.iterations ?? 0 },
      })
    }
  }

  return { nodes, edges, error }
}

function laneData(lane: Lane, expanded: boolean, onToggle: (laneID: string) => void) {
  return {
    laneID: lane.id,
    title: lane.title,
    status: lane.status,
    section: lane.section,
    sessionChip: lane.sessionChip ?? null,
    detail: lane.detail ?? null,
    detailUnavailable: lane.detailUnavailable,
    prState: lane.prState ?? null,
    blocked: lane.blocked,
    done: lane.progress.done,
    total: lane.progress.total,
    startedAt: null,
    expanded,
    onToggle,
  }
}

export { LANE_GAP_Y }
