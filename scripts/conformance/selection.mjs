import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

export function loadRequirements(runner, revision) {
  const { parse } = createRequire(path.join(runner, 'package.json'))('yaml');
  return parse(fs.readFileSync(path.join(runner, 'requirements', `${revision}.yaml`), 'utf8'));
}

export function scenarioGroup(scenario) {
  if (scenario.startsWith('json-schema-')) return 'schema';
  if (scenario.startsWith('http-')) return 'headers';
  if (scenario.startsWith('tasks-')) return 'tasks';
  if (scenario.startsWith('auth/')) return 'auth';
  if (scenario === 'server-session-lifecycle' || scenario === 'server-sse-polling') return 'legacy';
  return 'other';
}

export function selectScenarios(requirements, leg, mode, groups) {
  const inventory = [
    ...requirements[leg].map(scenario => ({
      scenario, required: true, reason: 'required', selected: mode !== 'optional'
    })),
    ...requirements.not_scored.filter(s => s.leg === leg).map(s => ({
      ...s, required: false, group: scenarioGroup(s.scenario),
      selected: mode !== 'required' && (groups.includes('all') || groups.includes(scenarioGroup(s.scenario)))
    }))
  ];
  if (new Set(inventory.map(s => s.scenario)).size !== inventory.length) {
    throw Error('Duplicate scenario in requirements');
  }
  return inventory;
}
