import type { Theme } from './types'

let reduceMotion = false

/** Swift stays the source of truth for status colour — it pushes the five
 *  `FlowStatusGlyph` colours plus surface/text/accent as CSS custom
 *  properties, and this only applies them. */
export function applyTheme(theme: Theme): void {
  const root = document.documentElement
  for (const [name, value] of Object.entries(theme.vars)) {
    // Only ever set custom properties — never arbitrary CSS.
    if (name.startsWith('--')) root.style.setProperty(name, value)
  }
  reduceMotion = theme.reduceMotion
  root.dataset.reduceMotion = theme.reduceMotion ? 'true' : 'false'
}

export function prefersReducedMotion(): boolean {
  return reduceMotion
}

/** "2h 14m" / "45s" — the canvas formats its own live tickers; the native
 *  inspector keeps using DateComponentsFormatter. */
export function elapsed(fromISO: string, toISO?: string | null): string {
  const from = Date.parse(fromISO)
  if (Number.isNaN(from)) return ''
  const to = toISO ? Date.parse(toISO) : Date.now()
  if (Number.isNaN(to)) return ''
  const seconds = Math.max(0, Math.round((to - from) / 1000))
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (hours > 0) return `${hours}h ${minutes}m`
  if (minutes > 0) return `${minutes}m ${seconds % 60}s`
  return `${seconds}s`
}
