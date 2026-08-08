import { Handle, Position, type NodeProps } from '@xyflow/react'
import { elapsed } from '../theme'

export interface LaneNodeData extends Record<string, unknown> {
  laneID: string
  title: string
  status: string
  section: string
  sessionChip?: string | null
  detail?: string | null
  detailUnavailable: boolean
  prState?: string | null
  blocked: boolean
  done: number
  total: number
  startedAt?: string | null
  expanded: boolean
  onToggle(laneID: string): void
}

export function LaneNode({ data, selected }: NodeProps): JSX.Element {
  const lane = data as LaneNodeData
  const classes = [
    'lane',
    `status-${lane.status}`,
    lane.blocked ? 'blocked' : '',
    lane.section === 'finished' ? 'finished' : '',
    lane.expanded ? 'expanded' : '',
    selected ? 'selected' : '',
  ].filter(Boolean).join(' ')

  const ratio = lane.total > 0 ? lane.done / lane.total : 0

  return (
    <div className={classes}>
      <Handle type="target" position={Position.Top} isConnectable={false} />
      <div className="lane-header">
        <button
          className="lane-chevron"
          title={lane.expanded ? 'Collapse' : 'Expand'}
          onClick={(event) => {
            event.stopPropagation()
            lane.onToggle(lane.laneID)
          }}
        >
          {lane.expanded ? '▾' : '▸'}
        </button>
        <span className={`glyph status-${lane.status}`} />
        <span className="lane-title">{lane.title}</span>
        {lane.detailUnavailable
          ? <span className="lane-warning" title="Lane detail can no longer be trusted">⚠</span>
          : null}
        {lane.prState ? <span className="lane-pr">{lane.prState}</span> : null}
        {lane.sessionChip ? <span className="lane-chip">{lane.sessionChip}</span> : null}
        {lane.startedAt
          ? <span className="lane-elapsed">{elapsed(lane.startedAt)}</span>
          : null}
      </div>
      {lane.detail ? <div className="lane-detail">{lane.detail}</div> : null}
      <div className="lane-progress">
        <div className="lane-progress-fill" style={{ width: `${Math.round(ratio * 100)}%` }} />
      </div>
      <Handle type="source" position={Position.Bottom} isConnectable={false} />
    </div>
  )
}
