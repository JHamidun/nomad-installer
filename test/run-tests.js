'use strict';
/* Minimal smoke tests for the dependency engine (deps.js) with the Nomad-only
   component set. No external deps — run via `npm test`. */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const HMDeps = require('../src/renderer/deps.js');
const components = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'components.json'), 'utf8'));

// Build byId map from components.json (same shape the renderer uses).
const byId = {};
for (const g of components.groups) for (const c of g.components) byId[c.id] = c;

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.error(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}

console.log('deps.js — Nomad component set');

test('components.json содержит git, nomad, verify', () => {
  assert.ok(byId.git && byId.nomad && byId.verify);
});

test('installOrder ставит зависимости раньше зависимых', () => {
  const selected = { git: true, nomad: true, verify: true };
  const order = HMDeps.installOrder(selected, byId);
  assert.deepStrictEqual([...order].sort(), ['git', 'nomad', 'verify']);
  // Любой requires должен стоять раньше своего компонента.
  for (const id of order) {
    for (const r of (byId[id].requires || [])) {
      assert.ok(order.indexOf(r) < order.indexOf(id), `${r} должен идти раньше ${id}`);
    }
  }
});

test('enableWithDeps включает транзитивные зависимости', () => {
  const selected = { git: false, nomad: false, verify: false };
  HMDeps.enableWithDeps(selected, byId, 'nomad');
  assert.strictEqual(selected.nomad, true);
  for (const r of (byId.nomad.requires || [])) assert.strictEqual(selected[r], true);
});

test('disableDependents выключает тех, кто требует компонент', () => {
  const selected = { git: true, nomad: true, verify: true };
  HMDeps.disableDependents(selected, byId, 'git');
  assert.strictEqual(selected.git, false);
  // nomad не требует git → остаётся включён (git — мягкий усилитель).
  assert.strictEqual(selected.nomad, true);
});

console.log(`\n${passed} проверок пройдено.`);
