// SPDX-License-Identifier: MPL-2.0
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { evaluate, llvmCounts, lcovCounts, passes } from '../../scripts/check-coverage.mjs';

const expected = { repo: 'catachresis-colloquium/Cytoville', base: '1'.repeat(40),
  candidate: '2'.repeat(40), event: 'pull_request', run: '17', attempt: '2' };
function llvm(covered = 80, count = 100) {
  return JSON.stringify({ type: 'llvm.coverage.json.export', data: [{
    files: [{ filename: 'crates/cytoville-bevy/src/main.rs', summary: { lines: { covered, count } } }],
    totals: { lines: { covered, count } },
  }] });
}
function fixture(change = () => {}) {
  const directory = mkdtempSync(join(tmpdir(), 'cytoville-coverage-'));
  for (const role of ['base', 'candidate']) {
    const folder = join(directory, role);
    mkdirSync(folder);
    const reports = { 'llvm.json': llvm(), 'elixir.lcov':
      'SF:lib/server.ex\nDA:1,1\nDA:2,1\nDA:3,1\nDA:4,1\nDA:5,0\nLF:5\nLH:4\nend_of_record\n' };
    const receipt = { schema: 'cytoville.raw-coverage/1',
      scope: 'linux-rust-workspace+graphical+tls+elixir-server-v2', repo: expected.repo,
      base: expected.base, candidate: expected.candidate, commit: expected[role],
      role, run_id: expected.run, run_attempt: expected.attempt, event: expected.event,
      tests_passed: true, sha256: {} };
    for (const [name, bytes] of Object.entries(reports)) {
      receipt.sha256[name] = createHash('sha256').update(bytes).digest('hex');
      writeFileSync(join(folder, name), bytes);
      writeFileSync(join(folder, `${name}.meta.json`), JSON.stringify({
        schema: 'hypatia.proven-coverage.report-meta/1', repo: expected.repo,
        commit: expected[role], run_id: expected.run, role: 'raw',
      }));
    }
    change(receipt, role, folder);
    writeFileSync(join(folder, 'receipt.json'), JSON.stringify(receipt));
  }
  return directory;
}
function withFixture(change, check) {
  const directory = fixture(change);
  try { check(directory); } finally { rmSync(directory, { recursive: true, force: true }); }
}
test('both languages pass at the floor; an exact five-point drop passes', () => {
  withFixture(undefined, directory => assert.ok(evaluate(directory, expected).every(x => x.pass)));
  assert.ok(passes({ hit: 80n, found: 100n }, { hit: 85n, found: 100n }));
});
test('floor and drop are independent, exact, and weighted by executable lines', () => {
  assert.ok(!passes({ hit: 79999n, found: 100000n }, { hit: 0n, found: 1n }));
  assert.ok(!passes({ hit: 80n, found: 100n }, { hit: 85001n, found: 100000n }));
  assert.ok(passes({ hit: 90n, found: 100n }, { hit: 17n, found: 20n }));
});
test('merge-group evidence is accepted only for that event and exact SHAs', () => {
  withFixture(r => { r.event = 'merge_group'; }, directory => {
    assert.ok(evaluate(directory, { ...expected, event: 'merge_group' }).every(x => x.pass));
    assert.throws(() => evaluate(directory, expected));
  });
});
for (const [field, value] of Object.entries({
  schema: 'other', scope: 'core-only', repo: 'other/repo', commit: '3'.repeat(40),
  base: '3'.repeat(40), candidate: '3'.repeat(40), event: 'push', run_id: '16',
  run_attempt: '1', role: 'other', tests_passed: false,
})) {
  test(`refuses wrong ${field} for either revision`, () => {
    for (const rejectedRole of ['base', 'candidate']) {
      withFixture((receipt, role) => { if (role === rejectedRole) receipt[field] = value; },
        directory => assert.throws(() => evaluate(directory, expected)));
    }
  });
}
test('missing, stale, malformed and modified reports never become green', () => {
  for (const mutation of [
    folder => rmSync(join(folder, 'llvm.json')),
    folder => writeFileSync(join(folder, 'llvm.json'), '{}'),
    folder => writeFileSync(join(folder, 'llvm.json.meta.json'), '{}'),
    folder => writeFileSync(join(folder, 'elixir.lcov'), ''),
  ]) {
    withFixture((_receipt, role, folder) => { if (role === 'base') mutation(folder); },
      directory => assert.throws(() => evaluate(directory, expected)));
  }
});
test('LLVM refuses forged summaries, absent files, empty and invalid counts', () => {
  for (const pair of [[0, 0], [2, 1], [-1, 1], [1.1, 2], [1, '100'], [1, Number.MAX_SAFE_INTEGER + 1]]) {
    assert.throws(() => llvmCounts(llvm(...pair)));
  }
  const report = JSON.parse(llvm());
  report.data[0].totals.lines.covered = 100;
  assert.throws(() => llvmCounts(JSON.stringify(report)));
  report.data[0].files = [];
  assert.throws(() => llvmCounts(JSON.stringify(report)));
});
test('LCOV rejects truncated records, duplicates, missing and forged totals', () => {
  for (const text of ['', 'SF:lib/a.ex\nDA:1,0',
    'SF:lib/a.ex\nDA:1,0\nDA:1,1\nLF:2\nLH:1\nend_of_record',
    'SF:lib/a.ex\nDA:1,0\nLF:1\nLH:1\nend_of_record',
    'SF:../a.ex\nDA:1,1\nLF:1\nLH:1\nend_of_record',
    'SF:lib/a.ex\nDA:1,1\nend_of_record']) assert.throws(() => lcovCounts(text));
});
