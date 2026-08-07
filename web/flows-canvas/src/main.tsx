import { createRoot } from 'react-dom/client'
import './styles.css'
import type { DebugState } from './types'

declare global {
  interface Window {
    dreamuxFlows: {
      render(json: string): void
      applyTheme(json: string): void
      focusLane(json: string): void
      restoreLayout(json: string): void
      tidyUp(json: string): void
      debugState(): string
    }
    webkit?: { messageHandlers?: Record<string, { postMessage(body: unknown): void }> }
  }
}

function post(method: string, params: Record<string, unknown> = {}): void {
  window.webkit?.messageHandlers?.dreamuxFlows?.postMessage({ id: 0, method, params })
}

window.onerror = (message, source, line) =>
  post('jsError', { message: `${String(message)} (${source ?? '?'}:${line ?? 0})` })
window.onunhandledrejection = (event) =>
  post('jsError', { message: String(event.reason) })

const empty: DebugState = {
  mounted: false, nodeIDs: [], expanded: [], lanePositions: {}, zoom: 1,
}

window.dreamuxFlows = {
  render: () => {},
  applyTheme: () => {},
  focusLane: () => {},
  restoreLayout: () => {},
  tidyUp: () => {},
  debugState: () => JSON.stringify(empty),
}

createRoot(document.getElementById('root')!).render(<div />)
post('ready')
