import type { NodeProps } from '@xyflow/react'

export interface PhaseBandData extends Record<string, unknown> {
  title: string
}

export function PhaseBand({ data }: NodeProps): JSX.Element {
  const band = data as PhaseBandData
  return (
    <div className="band">
      <span className="band-title">{band.title.toUpperCase()}</span>
    </div>
  )
}
