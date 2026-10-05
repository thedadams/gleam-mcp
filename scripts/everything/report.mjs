import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [directory, stdioExit, httpExit] = process.argv.slice(2);
const sha = '5abed86c5317b833dd59907492d56c65981642aa';
const report = { referenceSha: sha, legs: {}, checks: [], setupErrors: [] };
for (const [name, exitValue] of [['stdio', stdioExit], ['http', httpExit]]) {
  const exit = Number(exitValue);
  try {
    const leg = JSON.parse(readFileSync(join(directory, `${name}-summary.json`), 'utf8'));
    if (leg.referenceSha !== sha) throw new Error('Report has a different reference SHA');
    if (!Array.isArray(leg.checks) || !leg.checks.length) throw new Error('No checks were reported');
    if (leg.checks.some((entry) => typeof entry.passed !== 'boolean')) throw new Error('Invalid check verdict');
    const failed = leg.checks.filter((entry) => !entry.passed).length;
    const incomplete = Number(leg.summary?.incomplete || 0);
    if (exit !== (incomplete ? 2 : failed ? 1 : 0)) throw new Error(`Process exit ${exit} disagrees with its report`);
    report.legs[name] = { ...leg, observedExit: exit };
    report.checks.push(...leg.checks.map((entry) => ({ ...entry, leg: name, name: `${name}:${entry.name}` })));
    report.setupErrors.push(...(leg.setupErrors || []).map((entry) => ({ ...entry, leg: name })));
    if (incomplete > (leg.setupErrors || []).length) report.setupErrors.push({ leg: name, message: 'Interrupted or otherwise incomplete execution' });
  } catch (error) {
    report.setupErrors.push({ leg: name, message: error.message, observedExit: exit });
  }
}
const failed = report.checks.filter((entry) => !entry.passed);
report.summary = { total: report.checks.length, passed: report.checks.length - failed.length, failed: failed.length, incomplete: report.setupErrors.length };
writeFileSync(join(directory, 'summary.json'), JSON.stringify(report, null, 2) + '\n');
writeFileSync(join(directory, 'summary.txt'), `${JSON.stringify(report.summary)}\n${failed.map((entry) => `FAIL ${entry.name}`).join('\n')}\n${report.setupErrors.map((entry) => `INCOMPLETE ${entry.leg}: ${entry.message || entry.error?.message || entry.stage}`).join('\n')}\n`);
console.log(`Combined Everything checks: ${JSON.stringify(report.summary)}`);
process.exitCode = report.summary.incomplete ? 2 : failed.length ? 1 : 0;
