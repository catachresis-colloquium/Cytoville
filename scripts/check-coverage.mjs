// SPDX-License-Identifier: MPL-2.0
// Raw line coverage only. This does not classify Hypatia proven evidence.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const sha = /^[0-9a-f]{40}$/;
const scope = 'linux-rust-workspace-all-targets+elixir-server-v1';
function requireThat(condition, message) {
  if (!condition) throw new Error(message);
}
function integer(value) {
  requireThat(Number.isSafeInteger(value) && value >= 0, 'invalid coverage count');
  return BigInt(value);
}
function counts(covered, total) {
  const hit = integer(covered), found = integer(total);
  requireThat(found > 0n && hit <= found, 'empty or inconsistent coverage');
  return { hit, found };
}
export function llvmCounts(text) {
  const report = JSON.parse(text);
  requireThat(report.type === 'llvm.coverage.json.export' && report.data?.length === 1,
    'invalid LLVM export');
  const data = report.data[0];
  requireThat(Array.isArray(data.files) && data.files.length > 0, 'no LLVM files');
  const names = new Set();
  let hit = 0n, found = 0n;
  for (const file of data.files) {
    requireThat(typeof file.filename === 'string' && file.filename.length > 0 &&
      !names.has(file.filename), 'missing or duplicate LLVM file');
    names.add(file.filename);
    const lines = file.summary?.lines;
    const h = integer(lines?.covered), f = integer(lines?.count);
    requireThat(h <= f, 'inconsistent LLVM file');
    hit += h; found += f;
  }
  const total = counts(data.totals?.lines?.covered, data.totals?.lines?.count);
  requireThat(hit === total.hit && found === total.found, 'LLVM totals disagree with files');
  return total;
}
export function lcovCounts(text) {
  const files = new Set();
  let record = null, hit = 0n, found = 0n;
  for (const line of text.trim().split(/\r?\n/)) {
    if (line.startsWith('SF:')) {
      const path = line.slice(3);
      requireThat(!record && /^lib\/.+\.ex$/.test(path) && !path.split('/').includes('..') &&
        !files.has(path), 'invalid or duplicate Elixir source');
      files.add(path); record = { lines: new Set(), hit: 0n, found: 0n };
    } else if (/^DA:[1-9][0-9]*,[0-9]+$/.test(line)) {
      requireThat(record, 'LCOV data outside record');
      const [number, calls] = line.slice(3).split(',');
      requireThat(!record.lines.has(number), 'duplicate LCOV line');
      record.lines.add(number); record.found++;
      if (BigInt(calls) > 0n) record.hit++;
    } else if (/^L[HF]:[0-9]+$/.test(line)) {
      const key = line.slice(0, 2);
      requireThat(record && record[key] === undefined, 'duplicate LCOV summary');
      record[key] = BigInt(line.slice(3));
    } else if (line === 'end_of_record') {
      requireThat(record && record.LF === record.found && record.LH === record.hit,
        'LCOV totals disagree with lines');
      hit += record.hit; found += record.found; record = null;
    } else {
      throw new Error('unexpected LCOV record');
    }
  }
  requireThat(!record && files.size > 0 && found > 0n, 'empty or incomplete LCOV export');
  return { hit, found };
}
export function passes(candidate, base) {
  // Exact rational comparisons: 79.999% must not round up to 80%.
  return candidate.hit * 100n >= candidate.found * 80n &&
    (base.hit * candidate.found - candidate.hit * base.found) * 100n <=
      5n * base.found * candidate.found;
}
export function evaluate(directory, expected) {
  requireThat(sha.test(expected.base) && sha.test(expected.candidate), 'invalid revision');
  requireThat(['pull_request', 'merge_group'].includes(expected.event), 'unsupported event');
  requireThat(/^[1-9][0-9]*$/.test(expected.run) && /^[1-9][0-9]*$/.test(expected.attempt),
    'invalid run identity');
  const results = {};
  for (const role of ['base', 'candidate']) {
    const folder = resolve(directory, role);
    const receipt = JSON.parse(readFileSync(resolve(folder, 'receipt.json'), 'utf8'));
    requireThat(receipt.schema === 'cytoville.raw-coverage/1' && receipt.scope === scope &&
      receipt.repo === expected.repo && receipt.commit === expected[role] &&
      receipt.base === expected.base && receipt.candidate === expected.candidate &&
      receipt.event === expected.event && receipt.run_id === expected.run &&
      receipt.run_attempt === expected.attempt && receipt.role === role &&
      receipt.tests_passed === true, `wrong or incomplete ${role} receipt`);
    results[role] = {};
    for (const [language, filename, parse] of [
      ['rust', 'llvm.json', llvmCounts], ['elixir', 'elixir.lcov', lcovCounts],
    ]) {
      const bytes = readFileSync(resolve(folder, filename));
      const digest = createHash('sha256').update(bytes).digest('hex');
      requireThat(receipt.sha256?.[filename] === digest, `${role} ${language} digest mismatch`);
      const meta = JSON.parse(readFileSync(resolve(folder, `${filename}.meta.json`), 'utf8'));
      requireThat(meta.schema === 'hypatia.proven-coverage.report-meta/1' &&
        meta.repo === expected.repo && meta.commit === expected[role] &&
        meta.run_id === expected.run && meta.role === 'raw', 'wrong report provenance');
      results[role][language] = parse(bytes.toString('utf8'));
    }
  }
  return ['rust', 'elixir'].map(language => {
    const candidate = results.candidate[language], base = results.base[language];
    return { language, candidate, base, pass: passes(candidate, base) };
  });
}
if (import.meta.main) {
  try {
    const rows = evaluate(process.argv[2], {
      repo: process.env.GITHUB_REPOSITORY, base: process.env.BASE_SHA,
      candidate: process.env.CANDIDATE_SHA, event: process.env.GITHUB_EVENT_NAME,
      run: process.env.GITHUB_RUN_ID, attempt: process.env.GITHUB_RUN_ATTEMPT,
    });
    for (const { language, candidate, base, pass } of rows) {
      const percent = value => (Number(value.hit) * 100 / Number(value.found)).toFixed(3);
      console.log(`${pass ? 'PASS' : 'FAIL'} ${language}: ${candidate.hit}/${candidate.found} ` +
        `(${percent(candidate)}%); base ${base.hit}/${base.found} (${percent(base)}%); floor 80%, maximum drop 5 points`);
    }
    if (rows.some(row => !row.pass)) process.exitCode = 1;
  } catch (error) {
    console.error(`REFUSED: ${error.message}`); process.exitCode = 1;
  }
}
