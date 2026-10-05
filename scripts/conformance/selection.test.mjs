import test from 'node:test';
import assert from 'node:assert/strict';
import { scenarioGroup, selectScenarios } from './selection.mjs';

const requirements = {
  server: ['initialize'], client: ['client-initialize'],
  not_scored: [
    { scenario: 'json-schema-tool', leg: 'server', reason: 'pending', note: 'Upstream note' },
    { scenario: 'http-headers', leg: 'client', reason: 'extension' },
    { scenario: 'tasks-result', leg: 'server', reason: 'extension' },
    { scenario: 'auth/discovery', leg: 'client', reason: 'optional' },
    { scenario: 'server-session-lifecycle', leg: 'server', reason: 'legacy' },
    { scenario: 'something-else', leg: 'server', reason: 'optional' }
  ]
};
const selected = inventory => inventory.filter(s => s.selected).map(s => s.scenario);

test('default groups select required and applicable optional scenarios by role', () => {
  const groups = ['schema', 'headers', 'tasks'];
  const server = selectScenarios(requirements, 'server', 'all', groups);
  assert.deepEqual(selected(server), ['initialize', 'json-schema-tool', 'tasks-result']);
  assert.deepEqual(selected(selectScenarios(requirements, 'client', 'all', groups)), ['client-initialize', 'http-headers']);
  assert.equal(server[1].reason, 'pending');
  assert.equal(server[1].note, 'Upstream note');
  assert.equal(server[1].group, 'schema');
});

test('required mode excludes every optional group', () => {
  assert.deepEqual(selected(selectScenarios(requirements, 'server', 'required', ['all'])), ['initialize']);
});

test('optional mode can select no scenarios for a role', () => {
  assert.deepEqual(selected(selectScenarios(requirements, 'client', 'optional', ['tasks'])), []);
});

test('all optional groups include legacy and uncategorized scenarios', () => {
  assert.deepEqual(selected(selectScenarios(requirements, 'server', 'optional', ['all'])), [
    'json-schema-tool', 'tasks-result', 'server-session-lifecycle', 'something-else'
  ]);
  assert.equal(scenarioGroup('server-sse-polling'), 'legacy');
  assert.equal(scenarioGroup('auth/discovery'), 'auth');
});

test('duplicates are rejected even if excluded from this run', () => {
  const duplicate = { ...requirements, not_scored: [...requirements.not_scored,
    { scenario: 'initialize', leg: 'server', reason: 'pending' }] };
  assert.throws(() => selectScenarios(duplicate, 'server', 'optional', ['tasks']), /Duplicate scenario/);
});
