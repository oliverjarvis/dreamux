import { describe, expect, it } from 'vitest'
import { Bridge, type Framed, type Timers, type Transport } from '../src/bridge'

/** Deterministic timer double — nothing in these tests waits on wall clock. */
class FakeTimers implements Timers {
  private next = 1
  private scheduled = new Map<number, { fn: () => void; ms: number }>()

  set(fn: () => void, ms: number): number {
    const handle = this.next++
    this.scheduled.set(handle, { fn, ms })
    return handle
  }

  clear(handle: number): void {
    this.scheduled.delete(handle)
  }

  get pending(): number {
    return this.scheduled.size
  }

  /** Fire every scheduled callback, in scheduling order. */
  runAll(): void {
    const entries = [...this.scheduled.entries()].sort((a, b) => a[0] - b[0])
    this.scheduled.clear()
    for (const [, entry] of entries) entry.fn()
  }
}

class Recorder implements Transport {
  readonly sent: Framed[] = []
  post(body: unknown): void {
    this.sent.push(body as Framed)
  }
}

describe('Bridge framing', () => {
  it('frames each message as {id, method, params} with a monotonic id', () => {
    const transport = new Recorder()
    const bridge = new Bridge(new FakeTimers())
    bridge.attach(transport)

    bridge.send('ready')
    bridge.send('selectNode', { laneID: 'plan-a.md', nodeID: 'task-3' })

    expect(transport.sent).toEqual([
      { id: 1, method: 'ready', params: {} },
      { id: 2, method: 'selectNode', params: { laneID: 'plan-a.md', nodeID: 'task-3' } },
    ])
  })
})

describe('Bridge queueing before attach', () => {
  it('holds messages until a transport attaches, then flushes in order', () => {
    const bridge = new Bridge(new FakeTimers())
    bridge.send('ready')
    bridge.send('saveViewport', { x: 1, y: 2, zoom: 1 })
    expect(bridge.pendingCount).toBe(2)

    const transport = new Recorder()
    bridge.attach(transport)

    expect(bridge.pendingCount).toBe(0)
    expect(transport.sent.map((m) => m.method)).toEqual(['ready', 'saveViewport'])
    // Ids are assigned at send time, so order is preserved through the queue.
    expect(transport.sent.map((m) => m.id)).toEqual([1, 2])
  })

  it('sends straight through once attached', () => {
    const transport = new Recorder()
    const bridge = new Bridge(new FakeTimers())
    bridge.attach(transport)
    bridge.send('ready')
    expect(bridge.pendingCount).toBe(0)
    expect(transport.sent).toHaveLength(1)
  })
})

describe('Bridge debounce coalescing', () => {
  it('collapses repeated sends under one key into the LAST payload', () => {
    const timers = new FakeTimers()
    const transport = new Recorder()
    const bridge = new Bridge(timers)
    bridge.attach(transport)

    bridge.sendDebounced('viewport', 'saveViewport', { x: 1, y: 1, zoom: 1 }, 250)
    bridge.sendDebounced('viewport', 'saveViewport', { x: 2, y: 2, zoom: 1 }, 250)
    bridge.sendDebounced('viewport', 'saveViewport', { x: 3, y: 3, zoom: 2 }, 250)

    expect(transport.sent).toHaveLength(0)
    expect(timers.pending).toBe(1)

    timers.runAll()
    expect(transport.sent).toEqual([
      { id: 1, method: 'saveViewport', params: { x: 3, y: 3, zoom: 2 } },
    ])
  })

  it('keeps distinct keys independent', () => {
    const timers = new FakeTimers()
    const transport = new Recorder()
    const bridge = new Bridge(timers)
    bridge.attach(transport)

    bridge.sendDebounced('positions:lane-a', 'saveNodePositions',
      { laneID: 'lane-a', positions: [] }, 250)
    bridge.sendDebounced('positions:lane-b', 'saveNodePositions',
      { laneID: 'lane-b', positions: [] }, 250)

    expect(timers.pending).toBe(2)
    timers.runAll()
    expect(transport.sent.map((m) => (m.params as { laneID: string }).laneID))
      .toEqual(['lane-a', 'lane-b'])
  })

  it('flush() sends every pending debounced payload immediately', () => {
    const timers = new FakeTimers()
    const transport = new Recorder()
    const bridge = new Bridge(timers)
    bridge.attach(transport)

    bridge.sendDebounced('viewport', 'saveViewport', { x: 9, y: 9, zoom: 1 }, 250)
    bridge.flush()

    expect(transport.sent).toEqual([
      { id: 1, method: 'saveViewport', params: { x: 9, y: 9, zoom: 1 } },
    ])
    // The timer was cancelled, so firing it later must not double-send.
    timers.runAll()
    expect(transport.sent).toHaveLength(1)
  })

  it('debounced payloads queue too when no transport is attached', () => {
    const timers = new FakeTimers()
    const bridge = new Bridge(timers)
    bridge.sendDebounced('viewport', 'saveViewport', { x: 1, y: 1, zoom: 1 }, 250)
    timers.runAll()
    expect(bridge.pendingCount).toBe(1)

    const transport = new Recorder()
    bridge.attach(transport)
    expect(transport.sent).toHaveLength(1)
  })

  it('a transport that throws never breaks the caller', () => {
    const timers = new FakeTimers()
    const bridge = new Bridge(timers)
    bridge.attach({ post() { throw new Error('bridge gone') } })
    expect(() => bridge.send('ready')).not.toThrow()
  })
})
