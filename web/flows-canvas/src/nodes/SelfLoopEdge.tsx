import { BaseEdge, EdgeLabelRenderer, type EdgeProps } from '@xyflow/react'

const RADIUS = 18

/** A ~270° arc anchored on the node's trailing edge, open on the side
 *  facing the node so it reads as a loop departing and returning rather
 *  than a circle drawn on top of it. Built from explicit points so the
 *  open side is unambiguous regardless of axis direction. */
export function SelfLoopEdge({ id, sourceX, sourceY, data }: EdgeProps): JSX.Element {
  const iterations = (data as { iterations?: number } | undefined)?.iterations ?? 0
  const points: string[] = []
  for (let step = 0; step <= 24; step++) {
    const degrees = -135 + (270 * step) / 24
    const radians = (degrees * Math.PI) / 180
    const x = sourceX + RADIUS * Math.cos(radians)
    const y = sourceY + RADIUS * Math.sin(radians)
    points.push(`${step === 0 ? 'M' : 'L'} ${x} ${y}`)
  }

  return (
    <>
      <BaseEdge id={id} path={points.join(' ')} className="self-loop" />
      <EdgeLabelRenderer>
        <div
          className="self-loop-label nodrag nopan"
          style={{ transform: `translate(-50%, -50%) translate(${sourceX}px, ${sourceY + RADIUS + 10}px)` }}
        >
          ↺ ×{iterations}
        </div>
      </EdgeLabelRenderer>
    </>
  )
}
