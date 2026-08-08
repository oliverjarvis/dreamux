export interface XY { x: number; y: number }

export interface Progress { done: number; total: number }
export interface Aggregates { running: number; needsYou: number }

export interface WireNode {
  id: string
  kind: string
  label: string
  status: string
  group?: string | null
  multiplicity?: number | null
  lastActivity?: string | null
  startedAt?: string | null
  endedAt?: string | null
}

export interface WireEdge {
  from: string
  to: string
  kind: string
  iterations?: number | null
}

export interface Lane {
  id: string
  title: string
  kind: string
  status: string
  section: string
  sessionChip?: string | null
  detail?: string | null
  detailUnavailable: boolean
  prState?: string | null
  blocked: boolean
  progress: Progress
  planPath?: string | null
  dependsOn: string[]
  nodes: WireNode[]
  edges: WireEdge[]
}

export interface Snapshot {
  schemaVersion: number
  aggregates: Aggregates
  lanes: Lane[]
}

/** CSS custom properties pushed from Swift, plus the motion flag. */
export interface Theme {
  vars: Record<string, string>
  reduceMotion: boolean
}

export interface RestoreLayout {
  lanePositions: Record<string, XY>
  nodePositions: Record<string, Record<string, XY>>
  expandedLaneIDs: string[]
  viewport?: { x: number; y: number; zoom: number } | null
}

export interface FocusLaneRequest { laneID: string | null; expand: boolean }
export interface TidyUpRequest { laneID?: string | null }

export interface DebugState {
  mounted: boolean
  nodeIDs: string[]
  expanded: string[]
  lanePositions: Record<string, XY>
  zoom: number
}
