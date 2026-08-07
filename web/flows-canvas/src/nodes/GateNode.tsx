import { Handle, Position, type NodeProps } from '@xyflow/react'
import type { TaskNodeData } from './TaskNode'

export function GateNode({ data, selected }: NodeProps): JSX.Element {
  const gate = data as TaskNodeData
  return (
    <div className={`gate status-${gate.status}${selected ? ' selected' : ''}`}>
      <Handle type="target" position={Position.Top} isConnectable={false} />
      <span className={`glyph status-${gate.status}`} />
      {gate.detailed ? <span className="task-label">{gate.label}</span> : null}
      <Handle type="source" position={Position.Bottom} isConnectable={false} />
    </div>
  )
}
