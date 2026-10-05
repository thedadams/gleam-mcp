import test from 'node:test';
import assert from 'node:assert/strict';
import { summarizeScenario, outcome, totals, reportExitCode, renderReport } from './report.mjs';

function scenario(statuses, { required = true, exitCode = 0, log = '' } = {}) {
  const selection = { scenario: 'test-scenario', required, reason: required ? 'required' : 'pending' };
  const record = statuses && { file: '/results/checks.json', checks: statuses.map((status, id) => ({
    status, id, name: `Check ${id}`, description: `Description ${id}`
  })) };
  return summarizeScenario(selection, record, exitCode, log, '/results');
}

function result(scenarios, exitCode = 0) {
  return {
    revision: '2026-07-28', leg: 'server', exitCode,
    requiredNotRun: false, optionalNotRun: false, excludedScenarios: [], scenarios,
    required: totals(scenarios.filter(s => s.required)),
    notScored: totals(scenarios.filter(s => !s.required)), all: totals(scenarios)
  };
}

test('runner exit status takes precedence over successful checks', () => {
  const value = scenario(['SUCCESS'], { exitCode: 1 });
  assert.equal(outcome(value), 'failed');
  assert.match(value.executionFailure, /Official runner exited 1/);
  assert.equal(reportExitCode([result([value], 1)]), 1);
  assert.equal(totals([value]).scenariosPassed, 0);
});

test('optional failures do not change the required score', () => {
  const value = result([scenario(['SUCCESS']), scenario(['FAILURE'], { required: false, exitCode: 1 })], 1);
  assert.equal(value.required.scenariosPassed, 1);
  assert.equal(value.required.scenariosFailed, 0);
  assert.equal(value.notScored.scenariosFailed, 1);
  assert.equal(reportExitCode([value]), 1);
});

test('upstream optional whole-scenario skip succeeds and retains its explanation', () => {
  const value = scenario(['SKIPPED'], { required: false });
  assert.equal(outcome(value), 'skipped');
  assert.equal(value.skippedDetails[0].message, 'Description 0');
  assert.equal(reportExitCode([result([value])]), 0);
});

test('required whole-scenario skip is incomplete', () => {
  assert.equal(reportExitCode([result([scenario(['SKIPPED'])])]), 2);
});

test('partial skipped checks do not make a scenario skipped', () => {
  const value = scenario(['SUCCESS', 'SKIPPED', 'WARNING']);
  assert.equal(outcome(value), 'passed');
  assert.equal(value.skipped, false);
  assert.equal(value.skippedChecks, 1);
  assert.equal(value.warnings, 1);
  assert.equal(reportExitCode([result([value])]), 0);
});

test('missing artifacts and absent exit codes remain incomplete', () => {
  for (const value of [scenario(null), scenario(['SUCCESS'], { exitCode: null })]) {
    assert.equal(outcome(value), 'unmeasured');
    assert.equal(value.missingResults, true);
    assert.equal(reportExitCode([result([value])]), 2);
  }
});

test('official console counts can supply results when check artifacts are absent', () => {
  const value = scenario(null, { log: '✓ test-scenario: 3 passed, 0 failed\n' });
  assert.equal(value.passed, 3);
  assert.equal(value.missingResults, false);
  assert.equal(outcome(value), 'passed');
  const noExitCode = scenario(null, { exitCode: null, log: '✓ test-scenario: 3 passed, 0 failed' });
  assert.equal(noExitCode.missingResults, true);
});

test('failed execution without artifacts has one outcome and signals incomplete reporting', () => {
  const value = scenario(null, { exitCode: 1 });
  const counts = totals([value]);
  assert.equal(counts.scenariosFailed, 1);
  assert.equal(counts.scenariosNotMeasured, 0);
  assert.equal(counts.missingResults, 1);
  assert.equal(reportExitCode([result([value], 1)]), 2);
});

test('empty selections and excluded roles succeed; infrastructure failures return 2', () => {
  assert.equal(reportExitCode([result([]), { notRun: true }]), 0);
  assert.equal(totals([]).scenariosPassed, 0);
  assert.equal(reportExitCode([result([scenario(['SUCCESS'])], 2)]), 2);
});

test('rendered report keeps separate scores, exclusions, and skip reasons', () => {
  const value = result([scenario(['SUCCESS']), scenario(['SKIPPED'], { required: false })]);
  value.excludedScenarios = [{ scenario: 'auth/discovery', required: false }];
  const rendered = renderReport({
    mode: 'all', runnerVersion: 'test', runnerCommit: 'runner', sdkCommit: 'sdk',
    serverUrl: 'http://localhost', selection: 'Selected tests', results: [value],
    totalRequired: value.required, totalOptional: value.notScored
  });
  assert.match(rendered, /Total required scenarios: 1 passed, 0 failed, 0 skipped, 0 unmeasured/);
  assert.match(rendered, /Total optional scenarios: 0 passed, 0 failed, 1 skipped, 0 unmeasured/);
  assert.match(rendered, /Optional scenarios excluded: auth\/discovery/);
  assert.match(rendered, /Skipped test-scenario: Description 0/);
});
