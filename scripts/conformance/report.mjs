import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { loadRequirements } from './selection.mjs';

function checkFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? checkFiles(full) : entry.name === 'checks.json' ? [full] : [];
  });
}

export function summarizeScenario(selection, record, exitCode, log, output) {
  const { scenario } = selection;
  const checks = record?.checks;
  let passed = checks?.filter(c => c.status === 'SUCCESS').length || 0;
  let failed = checks?.filter(c => c.status === 'FAILURE').length || 0;
  let missingResults = !record || exitCode === null;
  if (!checks) {
    const line = log.split('\n').find(line => line.startsWith(`✓ ${scenario}: `) || line.startsWith(`✗ ${scenario}: `));
    const count = line?.match(/: (\d+) passed, (\d+) failed/);
    if (count) { passed = Number(count[1]); failed = Number(count[2]); missingResults = exitCode === null; }
  }
  return {
    scenario, required: selection.required, reason: selection.reason, group: selection.group || null,
    note: selection.note || null, exitCode, passed, failed,
    executionFailure: exitCode !== null && exitCode !== 0 ? `Official runner exited ${exitCode}; see logs/${scenario}.log.` : null,
    skippedChecks: checks?.filter(c => c.status === 'SKIPPED').length || 0,
    skippedDetails: checks?.filter(c => c.status === 'SKIPPED').map(c => ({ id: c.id, name: c.name, message: c.errorMessage || c.description })) || [],
    skipped: passed === 0 && failed === 0 && Boolean(checks?.some(c => c.status === 'SKIPPED')),
    missingResults,
    warnings: checks?.filter(c => c.status === 'WARNING').length || 0,
    checksFile: record ? path.relative(output, record.file) : null,
    failures: checks?.filter(c => c.status === 'FAILURE').map(c => ({ id: c.id, message: c.errorMessage || c.description })) || []
  };
}

export function outcome(scenario) {
  if (scenario.failed > 0 || (scenario.exitCode !== null && scenario.exitCode !== 0)) return 'failed';
  if (scenario.missingResults) return 'unmeasured';
  if (scenario.exitCode === 0 && scenario.passed > 0) return 'passed';
  if (scenario.exitCode === 0 && scenario.skipped) return 'skipped';
  return 'unmeasured';
}

export function totals(scenarios) {
  return {
    scenariosPassed: scenarios.filter(s => outcome(s) === 'passed').length,
    scenariosFailed: scenarios.filter(s => outcome(s) === 'failed').length,
    scenariosSkipped: scenarios.filter(s => outcome(s) === 'skipped').length,
    scenariosNotMeasured: scenarios.filter(s => outcome(s) === 'unmeasured').length,
    missingResults: scenarios.filter(s => s.missingResults).length,
    checksPassed: scenarios.reduce((n, s) => n + s.passed, 0),
    checksFailed: scenarios.reduce((n, s) => n + s.failed, 0),
    checksSkipped: scenarios.reduce((n, s) => n + s.skippedChecks, 0),
    warnings: scenarios.reduce((n, s) => n + s.warnings, 0)
  };
}

function readLeg(output, revision, leg, mode) {
  const directory = path.join(output, revision, leg);
  const exitCodes = new Map(fs.readFileSync(path.join(directory, 'scenario-exit-codes.tsv'), 'utf8')
    .trim().split('\n').filter(Boolean).map(line => {
      const [scenario, code] = line.split('\t');
      return [scenario, Number(code)];
    }));
  const recorded = new Map(checkFiles(directory).map(file => {
    const scenario = path.relative(directory, path.dirname(file))
      .replace(leg === 'server' ? /^server-/ : /$^/, '')
      .replace(/-\d{4}-\d{2}-\d{2}T.*$/, '');
    return [scenario, { file, checks: JSON.parse(fs.readFileSync(file, 'utf8')) }];
  }));
  const log = fs.readFileSync(path.join(directory, 'runner.log'), 'utf8').replace(/\x1b\[[0-9;]*m/g, '');
  const inventory = JSON.parse(fs.readFileSync(path.join(directory, 'selection.json'), 'utf8'));
  const scenarios = inventory.filter(s => s.selected).map(selection =>
    summarizeScenario(selection, recorded.get(selection.scenario), exitCodes.get(selection.scenario) ?? null, log, output));
  return {
    revision, leg, exitCode: Number(fs.readFileSync(path.join(directory, 'exit-code.txt'), 'utf8')),
    requiredNotRun: mode === 'optional', optionalNotRun: mode === 'required',
    excludedScenarios: inventory.filter(s => !s.selected).map(({ selected, ...scenario }) => scenario),
    required: totals(scenarios.filter(s => s.required)),
    notScored: totals(scenarios.filter(s => !s.required)), all: totals(scenarios), scenarios
  };
}

export function reportExitCode(results) {
  const measured = results.filter(r => !r.notRun);
  if (measured.some(r => r.all.missingResults > 0 || r.all.scenariosNotMeasured > 0 || r.required.scenariosSkipped > 0 || r.exitCode > 1)) return 2;
  return measured.some(r => r.all.scenariosFailed > 0) ? 1 : 0;
}

export function renderReport(report) {
  const { mode } = report;
  const lines = [
    `MCP conformance ${report.runnerVersion} (${report.runnerCommit})`,
    `SDK commit: ${report.sdkCommit}`, `Server: ${report.serverUrl}`,
    '', report.selection, '',
    'Revision | Role | Group | Scenarios pass/fail/skipped/unmeasured | Checks pass/fail/skipped'
  ];
  for (const result of report.results) {
    if (result.notRun) { lines.push(`${result.revision} | ${result.leg} | NOT RUN (${result.requiredScenarios} required scenarios): ${result.reason}`); continue; }
    for (const [group, count, notRun] of [['required', result.required, result.requiredNotRun], ['optional', result.notScored, result.optionalNotRun]]) {
      if (notRun) { lines.push(`${result.revision} | ${result.leg} | ${group} | NOT RUN (mode ${mode})`); continue; }
      lines.push(`${result.revision} | ${result.leg} | ${group} | ${count.scenariosPassed}/${count.scenariosFailed}/${count.scenariosSkipped}/${count.scenariosNotMeasured} | ${count.checksPassed}/${count.checksFailed}/${count.checksSkipped}`);
    }
    const excludedOptional = result.excludedScenarios.filter(s => !s.required);
    if (excludedOptional.length) lines.push(`  Optional scenarios excluded: ${excludedOptional.map(s => s.scenario).join(', ')}`);
    for (const scenario of result.scenarios.filter(s => s.skipped)) {
      const details = scenario.skippedDetails.map(c => c.message || c.name || c.id).filter(Boolean).join('; ');
      lines.push(`  Skipped ${scenario.scenario}: ${details || 'Skipped by the official runner.'}`);
    }
  }
  for (const [group, count, selected] of [['required', report.totalRequired, mode !== 'optional'], ['optional', report.totalOptional, mode !== 'required']]) {
    if (!selected) continue;
    lines.push('', `Total ${group} scenarios: ${count.scenariosPassed} passed, ${count.scenariosFailed} failed, ${count.scenariosSkipped} skipped, ${count.scenariosNotMeasured} unmeasured.`,
      `Total ${group} checks: ${count.checksPassed} passed, ${count.checksFailed} failed, ${count.checksSkipped} skipped.`);
  }
  return lines.join('\n') + '\n';
}

export function createReport(runner, output, revisions, legs, mode, groupList) {
  const read = name => fs.readFileSync(path.join(output, name), 'utf8').trim();
  const report = {
    sdkCommit: read('sdk-commit.txt'), sdkWorkingTree: read('sdk-working-tree.txt'),
    runnerCommit: read('runner-commit.txt'),
    runnerVersion: JSON.parse(fs.readFileSync(path.join(runner, 'package.json'))).version,
    serverUrl: read('server-url.txt'),
    serverModule: process.env.MCP_CONFORMANCE_SERVER_MODULE || 'conformance/server',
    mode, optionalGroups: groupList.trim().split(/\s+/),
    selection: `Mode: ${mode}. Optional groups: ${groupList}. Membership from the pinned official requirements.`,
    results: []
  };
  for (const revision of revisions.trim().split(/\s+/)) {
    const requirements = loadRequirements(runner, revision);
    for (const leg of ['server', 'client']) {
      report.results.push(legs.trim().split(/\s+/).includes(leg) ? readLeg(output, revision, leg, mode) : {
        revision, leg, notRun: true, requiredScenarios: requirements[leg].length,
        reason: 'Role excluded by MCP_CONFORMANCE_LEGS.'
      });
    }
  }
  const measured = report.results.filter(r => !r.notRun);
  report.totalRequired = totals(measured.flatMap(r => r.scenarios.filter(s => s.required)));
  report.totalOptional = totals(measured.flatMap(r => r.scenarios.filter(s => !s.required)));
  return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [runner, output, revisions, legs, mode, groupList] = process.argv.slice(2);
    const report = createReport(runner, output, revisions, legs, mode, groupList);
    const rendered = renderReport(report);
    fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify(report, null, 2) + '\n');
    fs.writeFileSync(path.join(output, 'summary.txt'), rendered);
    console.log(rendered.trimEnd());
    console.log(`\nDetailed results: ${path.join(output, 'summary.json')}`);
    process.exitCode = reportExitCode(report.results);
  } catch (error) {
    console.error(error);
    process.exitCode = 2;
  }
}
