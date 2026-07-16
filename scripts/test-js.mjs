#!/usr/bin/env node
// Unit tests for the pure logic in Sources/FreeMacMonitor/Resources/app.js.
// The script is browser-global style, so it runs inside a vm context with a
// minimal DOM stub. Run: node scripts/test-js.mjs

import { readFileSync } from 'fs';
import vm from 'vm';
import assert from 'assert';

const src = readFileSync(
  new URL('../Sources/FreeMacMonitor/Resources/app.js', import.meta.url),
  'utf8'
);

function stubElement() {
  return {
    textContent: '',
    innerHTML: '',
    style: {},
    className: '',
    children: [],
    classList: { add() {}, remove() {} },
  };
}

const ctx = {
  document: {
    getElementById: () => stubElement(),
    querySelector: () => stubElement(),
    body: { classList: { add() {}, remove() {} }, style: {} },
  },
  setInterval: () => 0,
  clearInterval: () => {},
  setTimeout: () => 0,
  clearTimeout: () => {},
  Date, JSON, Math, console,
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(src, ctx);

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`✗ ${name}\n  ${e.message}`);
    process.exitCode = 1;
  }
}

// --- allocateSegments: largest-remainder allocation ---

test('allocateSegments sums to SEGMENTS', () => {
  const mem = { total: 1000, app: 333, wired: 111, compressed: 99, cached: 240, free: 217 };
  const segs = ctx.allocateSegments(mem, 20);
  assert.strictEqual(segs.reduce((a, b) => a + b, 0), 20);
  segs.forEach(s => assert.ok(s >= 0));
});

test('allocateSegments handles a dominant category', () => {
  const mem = { total: 1000, app: 990, wired: 4, compressed: 3, cached: 2, free: 1 };
  const segs = ctx.allocateSegments(mem, 20);
  assert.strictEqual(segs.reduce((a, b) => a + b, 0), 20);
  assert.ok(segs[0] >= 18, `app got ${segs[0]} segments`);
});

test('allocateSegments survives total=0', () => {
  const mem = { total: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: 0 };
  const segs = ctx.allocateSegments(mem, 20);
  assert.strictEqual(segs.reduce((a, b) => a + b, 0), 20);
});

// --- pctSeverity boundaries ---

test('pctSeverity boundaries', () => {
  assert.strictEqual(ctx.pctSeverity(69.9), 'lit');
  assert.strictEqual(ctx.pctSeverity(70),   'warn');
  assert.strictEqual(ctx.pctSeverity(89.9), 'warn');
  assert.strictEqual(ctx.pctSeverity(90),   'crit');
});

// --- byte formatters ---

test('fmtBytes', () => {
  assert.strictEqual(ctx.fmtBytes(0), '--- GB');
  assert.strictEqual(ctx.fmtBytes(512 * 1024 * 1024), '512 MB');
  assert.strictEqual(ctx.fmtBytes(1.5 * 1024 * 1024 * 1024), '1.5 GB');
});

test('fmtMemBytes', () => {
  assert.strictEqual(ctx.fmtMemBytes(0), '0');
  assert.strictEqual(ctx.fmtMemBytes(512 * 1024 * 1024), '512M');
  assert.strictEqual(ctx.fmtMemBytes(2 * 1024 * 1024 * 1024), '2.0G');
});

// --- updateMetrics smoke test (must not throw on real-shaped data) ---

test('updateMetrics smoke', () => {
  ctx.window.updateMetrics({
    cpu: 42.3, memory: 63.8,
    memBreakdown: { total: 17179869184, app: 7516192768, wired: 2147483648,
                    compressed: 1288490189, cached: 4294967296, free: 1932735283 },
    gpuUsage: 27.5, diskUsed: 302000000000, diskTotal: 494000000000, diskPercent: 61.1,
  }, { showBreakdown: true, theme: 'fallout' });
  ctx.window.updateMetrics({ cpu: 0, memory: 0, memBreakdown: null, gpuUsage: -1,
                             diskUsed: 0, diskTotal: 0, diskPercent: 0 },
                           { showBreakdown: false, theme: 'liquid-glass' });
});

// --- clock visibility hook ---

test('setPanelVisible toggles the clock without throwing', () => {
  ctx.window.setPanelVisible(false);
  ctx.window.setPanelVisible(true);
});

if (process.exitCode !== 1) {
  console.log(`✓ ${passed} JS tests passed`);
}
