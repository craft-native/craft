#!/usr/bin/env bun

/**
 * Native STX Update Benchmark
 *
 * Compares the host-neutral work at the native bridge boundary:
 * - RENDER parses and reconciles an entire resolved tree.
 * - MUTATE parses one versioned batch and updates the addressed node.
 *
 * UIKit and Android widget costs vary by device, so this benchmark deliberately
 * measures only the shared JSON and retained-tree work that both hosts perform.
 */
import { bench, boxplot, run, summary } from 'mitata'
import { header } from './utils'

interface NativeNode {
  id: string
  type: string
  props: Record<string, unknown>
  style: Record<string, unknown>
  events: Record<string, string>
  children: Array<NativeNode | string>
}

function makeTree(count: number): NativeNode {
  return {
    id: 'root',
    type: 'View',
    props: { testID: 'benchmark-root' },
    style: { padding: 16, gap: 4 },
    events: {},
    children: Array.from({ length: count }, (_, index): NativeNode => ({
      id: `root/key:item-${index}`,
      type: 'Text',
      props: { testID: `item-${index}`, accessibilityLabel: `Item ${index}` },
      style: { color: '#123456', fontSize: 16 },
      events: {},
      children: [`Value ${index}`],
    })),
  }
}

function indexTree(node: NativeNode, controls: Map<string, NativeNode>): void {
  controls.set(node.id, node)
  for (const child of node.children) {
    if (typeof child !== 'string') indexTree(child, controls)
  }
}

function fullRenderWire(count: number): string {
  return JSON.stringify({
    type: 'RENDER',
    payload: { document: makeTree(count), mode: 'replace' },
  })
}

function mutationWire(count: number): string {
  return JSON.stringify({
    type: 'MUTATE',
    payload: {
      version: 1,
      batchId: 'benchmark-1',
      baseRevision: 1,
      revision: 2,
      operations: [{
        op: 'updateNode',
        id: `root/key:item-${count - 1}`,
        patch: { children: ['Updated'] },
      }],
    },
  })
}

function reconcileFull(wire: string): number {
  const message = JSON.parse(wire) as { payload: { document: NativeNode } }
  const controls = new Map<string, NativeNode>()
  indexTree(message.payload.document, controls)
  return controls.size
}

function reconcileMutation(wire: string, controls: Map<string, NativeNode>): number {
  const message = JSON.parse(wire) as {
    payload: { operations: Array<{ id: string, patch: { children: string[] } }> }
  }
  const operation = message.payload.operations[0]
  const previous = controls.get(operation.id)!
  controls.set(operation.id, { ...previous, children: operation.patch.children })
  return controls.size
}

header('Native STX Full-Tree vs Incremental Updates')

for (const count of [100, 1000]) {
  const render = fullRenderWire(count)
  const mutation = mutationWire(count)
  const controls = new Map<string, NativeNode>()
  indexTree(makeTree(count), controls)

  if (reconcileFull(render) !== count + 1 || reconcileMutation(mutation, controls) !== count + 1)
    throw new Error(`Native mutation benchmark setup failed for ${count} nodes`)

  console.log(`  ${count} nodes: RENDER ${Buffer.byteLength(render)} bytes, MUTATE ${Buffer.byteLength(mutation)} bytes`)
  boxplot(() => {
    summary(() => {
      bench(`RENDER ${count} nodes`, () => reconcileFull(render))
      bench(`MUTATE 1 of ${count} nodes`, () => reconcileMutation(mutation, controls))
    })
  })
}

await run()
