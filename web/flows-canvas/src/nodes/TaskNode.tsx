import { Handle, Position, type NodeProps } from '@xyflow/react'

export interface TaskNodeData extends Record<string, unknown> {
  label: string
  status: string
  multiplicity?: number | null
  /** Below ~0.5 scale children render as unlabelled status dots. */
  detailed: boolean
}

export function TaskNode({ data, selected }: NodeProps): JSX.Element {
  const task = data as TaskNodeData
  if (!task.detailed) {
    return (
      <div className={`dot status-${task.status}`} title={task.label}>
        <Handle type="target" position={Position.Top} isConnectable={false} />
        <Handle type="source" position={Position.Bottom} isConnectable={false} />
      </div>
    )
  }
  return (
    <div className={`task status-${task.status}${selected ? ' selected' : ''}`}>
      <Handle type="target" position={Position.Top} isConnectable={false} />
      <span className={`glyph status-${task.status}`} />
      <span className="task-label">{task.label}</span>
      {task.multiplicity && task.multiplicity > 1
        ? <span className="task-multiplicity">×{task.multiplicity}</span>
        : null}
      <Handle type="source" position={Position.Bottom} isConnectable={false} />
    </div>
  )
}
