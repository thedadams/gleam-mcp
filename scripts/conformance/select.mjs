import fs from 'node:fs';
import path from 'node:path';
import { loadRequirements, selectScenarios } from './selection.mjs';

const [runner, revision, leg, mode, groupList, destination] = process.argv.slice(2);
const inventory = selectScenarios(loadRequirements(runner, revision), leg, mode, groupList.trim().split(/\s+/));
fs.writeFileSync(path.join(destination, 'selection.json'), JSON.stringify(inventory, null, 2) + '\n');
console.log(inventory.filter(s => s.selected).map(s => s.scenario).join('\n'));
