import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const outdir = resolve(here, '../../Sources/Dreamux/Resources/FlowsCanvas')

await build({
  entryPoints: [resolve(here, 'src/main.tsx')],
  outdir,
  entryNames: 'bundle',
  bundle: true,
  minify: true,
  format: 'iife',
  // macOS 14 is the platform floor; its WKWebView is Safari 17.
  target: ['safari17'],
  jsx: 'automatic',
  define: { 'process.env.NODE_ENV': '"production"' },
  loader: { '.css': 'css' },
  logLevel: 'info',
})
