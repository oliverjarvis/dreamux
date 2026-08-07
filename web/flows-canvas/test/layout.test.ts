import { describe, expect, it } from 'vitest'
import {
  BAND_PADDING,
  hasCycle,
  layoutLaneInternals,
  layoutLanes,
  selfLoops,
  type LaneBox,
  type TaskBox,
  type TaskEdge,
} from '../src/layout'

const lane = (id: string, dependsOn: string[] = [], hasPlan = true): LaneBox =>
  ({ id, width: 260, height: 88, dependsOn, hasPlan })

const task = (id: string, group?: string): TaskBox =>
  ({ id, width: 150, height: 44, group })

describe('layoutLanes', () => {
  it('ranks a dependent lane strictly below its blocker', () => {
    const out = layoutLanes([lane('a'), lane('b', ['a'])])
    expect(out.fallback).toBe(false)
    expect(out.positions.b.y).toBeGreaterThan(out.positions.a.y)
  })

  it('chains three ranks in dependency order', () => {
    const out = layoutLanes([lane('a'), lane('b', ['a']), lane('c', ['b'])])
    expect(out.positions.a.y).toBeLessThan(out.positions.b.y)
    expect(out.positions.b.y).toBeLessThan(out.positions.c.y)
  })

  it('packs rootless lanes into a trailing column right of the DAG', () => {
    const out = layoutLanes([
      lane('a'), lane('b', ['a']),
      lane('adhoc-1', [], false), lane('adhoc-2', [], false),
    ])
    const dagRight = Math.max(
      out.positions.a.x + 260,
      out.positions.b.x + 260,
    )
    expect(out.positions['adhoc-1'].x).toBeGreaterThanOrEqual(dagRight)
    // Same column, stacked.
    expect(out.positions['adhoc-2'].x).toBe(out.positions['adhoc-1'].x)
    expect(out.positions['adhoc-2'].y).toBeGreaterThan(out.positions['adhoc-1'].y)
  })

  it('lets a saved position win over the computed one, per id', () => {
    const out = layoutLanes([lane('a'), lane('b', ['a'])], { b: { x: 999, y: -12 } })
    expect(out.positions.b).toEqual({ x: 999, y: -12 })
    // 'a' has no saved entry, so it keeps its auto-placement.
    expect(out.positions.a).not.toEqual({ x: 999, y: -12 })
  })

  it('auto-places a lane that appeared after positions were saved', () => {
    const out = layoutLanes([lane('a'), lane('new')], { a: { x: 0, y: 0 } })
    expect(out.positions.new).toBeDefined()
    expect(Number.isFinite(out.positions.new.x)).toBe(true)
    expect(Number.isFinite(out.positions.new.y)).toBe(true)
  })

  it('falls back to a single-column packing on cyclic input', () => {
    const out = layoutLanes([lane('a', ['b']), lane('b', ['a'])])
    expect(out.fallback).toBe(true)
    expect(out.positions.a.x).toBe(out.positions.b.x)
    expect(out.positions.b.y).toBeGreaterThan(out.positions.a.y)
  })

  it('returns an empty layout for no lanes', () => {
    const out = layoutLanes([])
    expect(out.positions).toEqual({})
    expect(out.size).toEqual({ width: 0, height: 0 })
    expect(out.fallback).toBe(false)
  })

  it('reports a size covering every placed lane', () => {
    const out = layoutLanes([lane('a'), lane('b', ['a'])])
    for (const id of ['a', 'b']) {
      expect(out.positions[id].x + 260).toBeLessThanOrEqual(out.size.width + 0.001)
      expect(out.positions[id].y + 88).toBeLessThanOrEqual(out.size.height + 0.001)
    }
  })
})

describe('layoutLaneInternals', () => {
  const chain: TaskEdge[] = [{ from: 't1', to: 't2' }, { from: 't2', to: 't3' }]

  it('emits parent-relative coordinates starting at the origin', () => {
    const out = layoutLaneInternals([task('t1'), task('t2'), task('t3')], chain)
    const xs = Object.values(out.positions).map((p) => p.x)
    const ys = Object.values(out.positions).map((p) => p.y)
    expect(Math.min(...xs)).toBe(0)
    expect(Math.min(...ys)).toBe(0)
  })

  it('ranks a chain top to bottom', () => {
    const out = layoutLaneInternals([task('t1'), task('t2'), task('t3')], chain)
    expect(out.positions.t1.y).toBeLessThan(out.positions.t2.y)
    expect(out.positions.t2.y).toBeLessThan(out.positions.t3.y)
  })

  it('excludes self-loops from dagre but still reports them', () => {
    const edges: TaskEdge[] = [...chain, { from: 't2', to: 't2' }]
    const out = layoutLaneInternals([task('t1'), task('t2'), task('t3')], edges)
    expect(out.fallback).toBe(false)
    expect(Object.keys(out.positions)).toHaveLength(3)
    expect(selfLoops(edges)).toEqual([{ from: 't2', to: 't2' }])
  })

  it('drops edges pointing at nodes that are not present', () => {
    const out = layoutLaneInternals([task('t1')], [{ from: 't1', to: 'ghost' }])
    expect(out.fallback).toBe(false)
    expect(out.positions.ghost).toBeUndefined()
  })

  it('lets a saved position win and auto-places new nodes', () => {
    const out = layoutLaneInternals(
      [task('t1'), task('t2'), task('t3')], chain, { t2: { x: 5, y: 500 } })
    expect(out.positions.t2).toEqual({ x: 5, y: 500 })
    expect(out.positions.t3).toBeDefined()
  })

  it('unions maximal runs of a shared group into inset bands', () => {
    const nodes = [
      task('src'),
      task('t1', 'Phase A'), task('t2', 'Phase A'),
      task('gate'),
      task('t3', 'Phase B'),
    ]
    const edges: TaskEdge[] = [
      { from: 'src', to: 't1' }, { from: 't1', to: 't2' },
      { from: 't2', to: 'gate' }, { from: 'gate', to: 't3' },
    ]
    const out = layoutLaneInternals(nodes, edges)
    expect(out.bands.map((b) => b.title)).toEqual(['Phase A', 'Phase B'])

    const phaseA = out.bands[0]
    const t1 = out.positions.t1
    const t2 = out.positions.t2
    expect(phaseA.x).toBeCloseTo(Math.min(t1.x, t2.x) - BAND_PADDING)
    expect(phaseA.y).toBeCloseTo(Math.min(t1.y, t2.y) - BAND_PADDING)
    expect(phaseA.width).toBeCloseTo(
      Math.max(t1.x + 150, t2.x + 150) - Math.min(t1.x, t2.x) + BAND_PADDING * 2)
  })

  it('starts a fresh band when an ungrouped node breaks the run', () => {
    const nodes = [task('t1', 'P'), task('gate'), task('t2', 'P')]
    const out = layoutLaneInternals(nodes, [
      { from: 't1', to: 'gate' }, { from: 'gate', to: 't2' },
    ])
    // Two runs of "P", not one union spanning the gate.
    expect(out.bands).toHaveLength(2)
    expect(out.bands.every((b) => b.title === 'P')).toBe(true)
  })

  it('falls back to a column on cyclic input', () => {
    const out = layoutLaneInternals(
      [task('t1'), task('t2')], [{ from: 't1', to: 't2' }, { from: 't2', to: 't1' }])
    expect(out.fallback).toBe(true)
    expect(out.positions.t1.x).toBe(out.positions.t2.x)
    expect(out.positions.t2.y).toBeGreaterThan(out.positions.t1.y)
  })

  it('returns an empty layout for no nodes', () => {
    const out = layoutLaneInternals([], [])
    expect(out.positions).toEqual({})
    expect(out.bands).toEqual([])
    expect(out.size).toEqual({ width: 0, height: 0 })
  })
})

describe('hasCycle', () => {
  it('ignores self-loops', () => {
    expect(hasCycle(['a'], [{ from: 'a', to: 'a' }])).toBe(false)
  })

  it('finds a two-node cycle and a three-node cycle', () => {
    expect(hasCycle(['a', 'b'], [{ from: 'a', to: 'b' }, { from: 'b', to: 'a' }])).toBe(true)
    expect(hasCycle(['a', 'b', 'c'], [
      { from: 'a', to: 'b' }, { from: 'b', to: 'c' }, { from: 'c', to: 'a' },
    ])).toBe(true)
  })

  it('accepts a diamond as acyclic', () => {
    expect(hasCycle(['a', 'b', 'c', 'd'], [
      { from: 'a', to: 'b' }, { from: 'a', to: 'c' },
      { from: 'b', to: 'd' }, { from: 'c', to: 'd' },
    ])).toBe(false)
  })
})
