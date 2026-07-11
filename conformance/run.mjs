import { execFile } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import { normalizeRun } from './normalize.mjs';
import { runTsScenario } from './runner-ts.mjs';
import { startScenarioServer } from './server.mjs';

const execFileAsync = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..');
const scenarioDirectory = path.join(here, 'scenarios');
const artifactDirectory = path.join(here, '.artifacts');
const zigRunner = path.join(repoRoot, 'zig-out', 'bin', 'conformance-runner');

function parseArguments(argv) {
  const result = { only: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--only') {
      result.only = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${argv[index]}`);
  }
  if (argv.includes('--only') && result.only == null) {
    throw new Error('--only requires a scenario name or file stem.');
  }
  return result;
}

async function loadScenarios(only) {
  const filenames = (await fs.readdir(scenarioDirectory))
    .filter(filename => filename.endsWith('.json'))
    .sort();
  const scenarios = [];
  for (const filename of filenames) {
    const scenario = JSON.parse(
      await fs.readFile(path.join(scenarioDirectory, filename), 'utf8'),
    );
    scenario.file = filename;
    if (
      only == null ||
      scenario.name === only ||
      path.basename(filename, '.json') === only
    ) {
      scenarios.push(scenario);
    }
  }
  if (scenarios.length === 0) {
    throw new Error(`No scenario matched ${JSON.stringify(only)}.`);
  }
  return scenarios;
}

async function runWithServer(scenario, callback) {
  const server = await startScenarioServer(scenario.server.responses);
  try {
    const result = await callback(server.baseURL);
    if (server.remainingResponses !== 0) {
      throw new Error(
        `${server.remainingResponses} canned response(s) were not consumed.`,
      );
    }
    return { requests: structuredClone(server.requests), result };
  } finally {
    await server.close();
  }
}

async function runZigScenario(scenario, scenarioPath, baseURL) {
  const { stdout, stderr } = await execFileAsync(
    zigRunner,
    [scenarioPath, baseURL],
    {
      cwd: repoRoot,
      env: { PATH: process.env.PATH ?? '' },
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      timeout: 60_000,
    },
  );
  try {
    return JSON.parse(stdout);
  } catch (error) {
    throw new Error(
      `Zig runner emitted invalid JSON for ${scenario.name}: ${error.message}\n` +
        `stdout: ${stdout}\nstderr: ${stderr}`,
    );
  }
}

function joinPath(parent, key) {
  if (typeof key === 'number') return `${parent}[${key}]`;
  return parent === '$' ? `$.${key}` : `${parent}.${key}`;
}

function collectDiffs(left, right, currentPath = '$', output = []) {
  if (Object.is(left, right)) return output;
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) {
      output.push({ path: currentPath, upstream: left, zig: right });
      return output;
    }
    if (left.length !== right.length) {
      output.push({
        path: `${currentPath}.length`,
        upstream: left.length,
        zig: right.length,
      });
    }
    const length = Math.min(left.length, right.length);
    for (let index = 0; index < length; index += 1) {
      collectDiffs(left[index], right[index], joinPath(currentPath, index), output);
    }
    return output;
  }
  if (
    left == null ||
    right == null ||
    typeof left !== 'object' ||
    typeof right !== 'object'
  ) {
    output.push({ path: currentPath, upstream: left, zig: right });
    return output;
  }

  const keys = [...new Set([...Object.keys(left), ...Object.keys(right)])].sort();
  for (const key of keys) {
    if (!(key in left) || !(key in right)) {
      output.push({
        path: joinPath(currentPath, key),
        upstream: left[key],
        zig: right[key],
      });
      continue;
    }
    collectDiffs(left[key], right[key], joinPath(currentPath, key), output);
  }
  return output;
}

function pathMatches(pattern, actual) {
  const escaped = pattern
    .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
    .replaceAll('*', '.*');
  return new RegExp(`^${escaped}(?:$|\\.|\\[)`).test(actual);
}

function ledgerCoverage(scenario, diffs) {
  const deviations = scenario.expected_deviations ?? [];
  const invalid = deviations.filter(
    deviation =>
      typeof deviation.reason !== 'string' ||
      !/fidelity ledger/i.test(deviation.reason),
  );
  if (invalid.length > 0) {
    return {
      covered: false,
      reasons: ['Every expected deviation must reference the fidelity ledger.'],
    };
  }
  const uncovered = diffs.filter(
    diff => !deviations.some(deviation => pathMatches(deviation.path, diff.path)),
  );
  return {
    covered: uncovered.length === 0 && diffs.length > 0,
    uncovered,
    reasons: deviations.map(deviation => `${deviation.path}: ${deviation.reason}`),
  };
}

function formatValue(value) {
  const encoded = JSON.stringify(value);
  if (encoded == null) return String(value);
  return encoded.length > 100 ? `${encoded.slice(0, 97)}...` : encoded;
}

async function evaluateScenario(scenario) {
  const scenarioPath = path.join(scenarioDirectory, scenario.file);
  try {
    const upstream = await runWithServer(scenario, baseURL =>
      runTsScenario(scenario, baseURL),
    );
    const zig = await runWithServer(scenario, baseURL =>
      runZigScenario(scenario, scenarioPath, baseURL),
    );

    if (upstream.result.skipped_reason || zig.result.skipped_reason) {
      return {
        name: scenario.name,
        surface: scenario.surface,
        status: 'SKIPPED',
        detail:
          zig.result.skipped_reason ?? upstream.result.skipped_reason,
        upstream,
        zig,
        diffs: [],
      };
    }

    const normalizedUpstream = normalizeRun(upstream, scenario);
    const normalizedZig = normalizeRun(zig, scenario);
    const diffs = collectDiffs(normalizedUpstream, normalizedZig);
    if (diffs.length === 0) {
      return {
        name: scenario.name,
        surface: scenario.surface,
        status: 'PASS',
        detail: 'Exact after normalization',
        upstream: normalizedUpstream,
        zig: normalizedZig,
        diffs,
      };
    }

    const coverage = ledgerCoverage(scenario, diffs);
    if (coverage.covered) {
      return {
        name: scenario.name,
        surface: scenario.surface,
        status: 'LEDGERED',
        detail: coverage.reasons.join('; '),
        upstream: normalizedUpstream,
        zig: normalizedZig,
        diffs,
      };
    }

    const first = coverage.uncovered?.[0] ?? diffs[0];
    return {
      name: scenario.name,
      surface: scenario.surface,
      status: 'FAIL',
      detail: `${first.path}: upstream=${formatValue(first.upstream)} zig=${formatValue(first.zig)}`,
      upstream: normalizedUpstream,
      zig: normalizedZig,
      diffs,
    };
  } catch (error) {
    return {
      name: scenario.name,
      surface: scenario.surface,
      status: 'FAIL',
      detail: `Harness error: ${error.message}`,
      diffs: [],
    };
  }
}

function escapeCell(value) {
  return String(value).replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function rollup(results) {
  const surfaces = new Map();
  for (const result of results) {
    const counts = surfaces.get(result.surface) ?? {
      total: 0,
      pass: 0,
      ledgered: 0,
      skipped: 0,
      fail: 0,
    };
    counts.total += 1;
    counts[result.status.toLowerCase()] += 1;
    surfaces.set(result.surface, counts);
  }
  return [...surfaces.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([surface, counts]) => ({ surface, ...counts }));
}

function markdownReport(results, surfaces, pins) {
  const lines = [
    '# Differential conformance report',
    '',
    `Pinned target: \`ai@${pins.ai}\`, \`@ai-sdk/openai@${pins.openai}\`, \`@ai-sdk/anthropic@${pins.anthropic}\`, \`@ai-sdk/provider@${pins.provider}\`.`,
    '',
    '## Scenarios',
    '',
    '| Scenario | Surface | Status | Detail |',
    '| --- | --- | --- | --- |',
  ];
  for (const result of results) {
    lines.push(
      `| ${escapeCell(result.name)} | ${escapeCell(result.surface)} | ${result.status} | ${escapeCell(result.detail)} |`,
    );
  }
  lines.push(
    '',
    '## Per-surface rollup',
    '',
    '| Surface | Total | PASS | LEDGERED | SKIPPED | FAIL |',
    '| --- | ---: | ---: | ---: | ---: | ---: |',
  );
  for (const surface of surfaces) {
    lines.push(
      `| ${escapeCell(surface.surface)} | ${surface.total} | ${surface.pass} | ${surface.ledgered} | ${surface.skipped} | ${surface.fail} |`,
    );
  }
  lines.push('');
  return lines.join('\n');
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  await fs.access(zigRunner).catch(() => {
    throw new Error(
      `Missing ${zigRunner}; run \`zig build conformance-runner\` first.`,
    );
  });
  const scenarios = await loadScenarios(options.only);
  const results = [];
  for (const scenario of scenarios) {
    const result = await evaluateScenario(scenario);
    results.push(result);
    console.log(`${result.status.padEnd(8)} ${result.name}`);
  }

  const packageJson = JSON.parse(
    await fs.readFile(path.join(here, 'package.json'), 'utf8'),
  );
  const pins = {
    ai: packageJson.dependencies.ai,
    openai: packageJson.dependencies['@ai-sdk/openai'],
    anthropic: packageJson.dependencies['@ai-sdk/anthropic'],
    provider: packageJson.dependencies['@ai-sdk/provider'],
  };
  const surfaces = rollup(results);
  const report = { pins, scenarios: results, surfaces };
  const markdown = markdownReport(results, surfaces, pins);
  await fs.mkdir(artifactDirectory, { recursive: true });
  await Promise.all([
    fs.writeFile(
      path.join(artifactDirectory, 'report.json'),
      `${JSON.stringify(report, null, 2)}\n`,
    ),
    fs.writeFile(path.join(artifactDirectory, 'report.md'), markdown),
  ]);
  console.log(`\n${markdown}`);
  if (results.some(result => result.status === 'FAIL')) process.exitCode = 1;
}

await main();
