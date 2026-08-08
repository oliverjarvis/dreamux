/** Canvas → native plumbing. Pure: the transport and the timer source are
 *  both injected, so framing, queueing and debounce are unit-tested with
 *  no WebKit and no wall clock. */

export interface Transport {
  post(body: unknown): void
}

export interface Timers {
  set(fn: () => void, ms: number): number
  clear(handle: number): void
}

export interface Framed {
  id: number
  method: string
  params: Record<string, unknown>
}

/** Drag-end and viewport moves fire in bursts; one write per burst is
 *  plenty for a file that only has to survive a relaunch. */
export const DEBOUNCE_MS = 250

const realTimers: Timers = {
  set: (fn, ms) => setTimeout(fn, ms) as unknown as number,
  clear: (handle) => clearTimeout(handle as unknown as ReturnType<typeof setTimeout>),
}

export class Bridge {
  private transport: Transport | null = null
  private queue: Framed[] = []
  private nextID = 1
  /** Holds the payload, NOT a framed message: the id is allocated when the
   *  message actually goes out, so a coalesced burst consumes exactly one
   *  id rather than one per superseded call. */
  private debounced = new Map<
    string, { handle: number; method: string; params: Record<string, unknown> }
  >()

  constructor(private readonly timers: Timers = realTimers) {}

  /** Messages sent before this lands are held, not dropped — the bundle
   *  runs before `window.webkit` is guaranteed to be reachable. */
  attach(transport: Transport): void {
    this.transport = transport
    const queued = this.queue
    this.queue = []
    for (const framed of queued) this.deliver(framed)
  }

  get pendingCount(): number {
    return this.queue.length
  }

  send(method: string, params: Record<string, unknown> = {}): void {
    this.deliver({ id: this.nextID++, method, params })
  }

  /** Replaces any pending payload under `key`, so a burst of drags or
   *  viewport moves collapses into a single native write. */
  sendDebounced(
    key: string,
    method: string,
    params: Record<string, unknown>,
    ms: number = DEBOUNCE_MS,
  ): void {
    const existing = this.debounced.get(key)
    if (existing) this.timers.clear(existing.handle)

    const handle = this.timers.set(() => {
      this.debounced.delete(key)
      this.send(method, params)
    }, ms)
    this.debounced.set(key, { handle, method, params })
  }

  /** Send every pending debounced payload now — used when the canvas is
   *  about to lose the window, so a just-finished drag is never lost. */
  flush(): void {
    const entries = [...this.debounced.values()]
    this.debounced.clear()
    for (const entry of entries) {
      this.timers.clear(entry.handle)
      this.send(entry.method, entry.params)
    }
  }

  private deliver(framed: Framed): void {
    if (!this.transport) {
      this.queue.push(framed)
      return
    }
    try {
      this.transport.post(framed)
    } catch {
      // A dead message handler must never take the canvas down with it —
      // the native side surfaces its own load/crash state.
    }
  }
}

/** The real WebKit transport. Returns a no-op post when the handler is
 *  absent (e.g. the bundle opened outside a WKWebView). */
export function webkitTransport(handlerName: string): Transport {
  return {
    post(body: unknown): void {
      const handlers = (window as unknown as {
        webkit?: { messageHandlers?: Record<string, { postMessage(b: unknown): void }> }
      }).webkit?.messageHandlers
      handlers?.[handlerName]?.postMessage(body)
    },
  }
}
