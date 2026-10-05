#!/usr/bin/env bash
# Run official scenarios using this SDK's dedicated conformance fixtures.
# Dependencies: Bash, Git, Node.js >= 20, npm, Gleam, curl, and pgrep.
# Results are retained outside the repository; downloaded tools are temporary.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'HELP'
Usage: scripts/run-conformance.sh [--mode required|optional|all] [RESULTS_DIRECTORY]

Runs the dedicated Gleam fixtures for 2025-11-25 and 2026-07-28. The default
mode is required. Optional mode selects schema preservation, HTTP headers, and
tasks from the official unscored lists; all mode runs required plus selected
optional scenarios. Required and optional results are reported separately.
Membership comes from the pinned official requirements files; no expected-failure
baseline is applied. Pending scenarios run for visibility and may be skipped
by the official runner.

Environment overrides:
  MCP_CONFORMANCE_RUNNER          Existing built conformance Git checkout
  MCP_CONFORMANCE_REF             Official runner commit (pinned by default)
  MCP_CONFORMANCE_REVISIONS       Space-separated revisions to run
  MCP_CONFORMANCE_LEGS            Space-separated roles (default: server client)
  MCP_CONFORMANCE_MODE            required, optional, or all (default: required)
  MCP_CONFORMANCE_OPTIONAL_GROUPS  Space-separated groups (default: schema headers tasks)
                                  Choices: schema, headers, tasks, auth, legacy, other, all
  MCP_CONFORMANCE_TIMEOUT_MS      Per-scenario timeout (default: 30000)
  MCP_CONFORMANCE_PORT            Dedicated server port (default: free port)
  MCP_CONFORMANCE_URL             Test an already running server instead
  MCP_CONFORMANCE_SERVER_MODULE   Gleam server module (default: conformance/server)
  MCP_CONFORMANCE_CLIENT_COMMAND  Override the conformance/client launcher

Excluded roles and optional groups are reported as not run. Exit 1 means a
selected scenario failed; optional failures do not change the required score.
Exit 2 means incomplete results or setup failure. Required skips are incomplete;
upstream optional skips are reported without failing the run. Raw results, logs, and
summary.json/summary.txt are saved in RESULTS_DIRECTORY (a new temp directory
by default). The script does not alter SDK source or create a bookmark.
HELP
  exit 0
fi
mode=${MCP_CONFORMANCE_MODE:-required}
optional_groups=${MCP_CONFORMANCE_OPTIONAL_GROUPS:-schema headers tasks}
results_arg=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { printf '%s\n' '--mode requires a value.' >&2; exit 2; }
      mode=$2
      shift 2
      ;;
    -*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)
      [[ -z "$results_arg" ]] || { printf 'Use --help for usage.\n' >&2; exit 2; }
      results_arg=$1
      shift
      ;;
  esac
done
case "$mode" in required|optional|all) ;; *) printf 'Invalid mode: %s\n' "$mode" >&2; exit 2 ;; esac
for group in $optional_groups; do
  case "$group" in schema|headers|tasks|auth|legacy|other|all) ;;
    *) printf 'Invalid optional group: %s\n' "$group" >&2; exit 2 ;;
  esac
done

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runner_ref=${MCP_CONFORMANCE_REF:-c37eec888e1c6ff140af79987a40008548b7cc5f}
revisions=${MCP_CONFORMANCE_REVISIONS:-2025-11-25 2026-07-28}
timeout_ms=${MCP_CONFORMANCE_TIMEOUT_MS:-30000}
server_module=${MCP_CONFORMANCE_SERVER_MODULE:-conformance/server}
legs=${MCP_CONFORMANCE_LEGS:-server client}
client_command=${MCP_CONFORMANCE_CLIENT_COMMAND:-}
server_pid=
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/gleam-mcp-conformance-tools.XXXXXX")
results_dir=${results_arg:-$(mktemp -d "${TMPDIR:-/tmp}/gleam-mcp-conformance-results.XXXXXX")}
mkdir -p -- "$results_dir"
results_dir=$(cd -- "$results_dir" && pwd)
[[ -z $(ls -A "$results_dir") ]] || {
  printf 'Results directory must be empty: %s\n' "$results_dir" >&2
  rm -rf -- "$work_dir"
  exit 2
}

stop_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    stop_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}
cleanup() {
  if [[ -n "$server_pid" ]]; then
    stop_tree "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Conformance setup/run failed near line %s; see %s\n" "$LINENO" "$results_dir" >&2; exit 2' ERR

for dependency in git node npm gleam curl pgrep; do
  command -v "$dependency" >/dev/null || {
    printf 'Missing dependency: %s\n' "$dependency" >&2
    exit 2
  }
done
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(2)'
for revision in $revisions; do
  case "$revision" in
    2025-11-25|2026-07-28) ;;
    *) printf 'Unsupported SDK revision: %s\n' "$revision" >&2; exit 2 ;;
  esac
done
for leg in $legs; do
  case "$leg" in server|client) ;; *) printf 'Invalid role: %s\n' "$leg" >&2; exit 2 ;; esac
done
[[ "$timeout_ms" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid timeout.\n' >&2; exit 2; }

runner_dir=${MCP_CONFORMANCE_RUNNER:-$work_dir/conformance}
if [[ -z ${MCP_CONFORMANCE_RUNNER:-} ]]; then
  git init -q "$runner_dir"
  git -C "$runner_dir" remote add origin https://github.com/modelcontextprotocol/conformance.git
  git -C "$runner_dir" fetch -q --depth 1 origin "$runner_ref"
  git -C "$runner_dir" checkout -q --detach FETCH_HEAD
  (cd "$runner_dir" && npm ci --no-audit --no-fund) >"$results_dir/runner-build.log" 2>&1
fi
runner_dir=$(cd -- "$runner_dir" && pwd)
[[ -f "$runner_dir/dist/index.js" ]] || {
  printf 'Runner is not built: %s\n' "$runner_dir" >&2
  exit 2
}
git -C "$repo_dir" rev-parse HEAD >"$results_dir/sdk-commit.txt"
git -C "$repo_dir" status --porcelain >"$results_dir/sdk-working-tree.txt"
git -C "$runner_dir" rev-parse HEAD >"$results_dir/runner-commit.txt"
if [[ -z "$client_command" && " $legs " == *" client "* ]]; then
  printf '#!/usr/bin/env bash\nset -euo pipefail\ncd %q\nexec gleam run -m conformance/client -- "$@"\n' "$repo_dir" >"$work_dir/run-client.sh"
  chmod +x "$work_dir/run-client.sh"
  printf -v client_command '%q' "$work_dir/run-client.sh"
fi

url=${MCP_CONFORMANCE_URL:-}
if [[ -z "$url" && " $legs " == *" server "* ]]; then
  port=${MCP_CONFORMANCE_PORT:-$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')}
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
    printf 'Invalid port.\n' >&2; exit 2
  }
  (cd "$repo_dir" && gleam build) >"$results_dir/sdk-build.log" 2>&1
  (cd "$repo_dir" && exec gleam run -m "$server_module" -- streamableHttp "$port") >"$results_dir/server.log" 2>&1 &
  server_pid=$!
  url="http://127.0.0.1:$port/mcp"
  ready=false
  for ((attempt=0; attempt<60; attempt++)); do
    kill -0 "$server_pid" 2>/dev/null || break
    if curl --silent --max-time 1 --output /dev/null "$url"; then
      ready=true
      break
    fi
    sleep 0.25
  done
  if [[ "$ready" != true ]]; then
    cat "$results_dir/server.log" >&2
    printf 'SDK server failed to become ready.\n' >&2
    exit 2
  fi
fi
printf '%s\n' "${url:-not run (client scenarios use runner-provided URLs)}" >"$results_dir/server-url.txt"
printf 'Testing %s %s scenarios; results: %s\n' "$mode" "$legs" "$results_dir"

for revision in $revisions; do
  for leg in server client; do
    [[ " $legs " == *" $leg "* ]] || continue
    destination="$results_dir/$revision/$leg"
    mkdir -p "$destination"
    if [[ "$leg" == server ]]; then
      target=(--url "$url")
    else
      target=(--command "$client_command")
    fi
    scenarios=$(node - "$runner_dir" "$revision" "$leg" "$mode" "$optional_groups" "$destination" <<'SCENARIOS'
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const [runner, revision, leg, mode, groupList, destination] = process.argv.slice(2);
const { parse } = createRequire(path.join(runner, 'package.json'))('yaml');
const requirements = parse(fs.readFileSync(path.join(runner, 'requirements', `${revision}.yaml`), 'utf8'));
const groups = groupList.trim().split(/\s+/);
function group(scenario) {
  if (scenario.startsWith('json-schema-')) return 'schema';
  if (scenario.startsWith('http-')) return 'headers';
  if (scenario.startsWith('tasks-')) return 'tasks';
  if (scenario.startsWith('auth/')) return 'auth';
  if (scenario === 'server-session-lifecycle' || scenario === 'server-sse-polling') return 'legacy';
  return 'other';
}
const inventory = [
  ...requirements[leg].map(scenario => ({ scenario, required: true, reason: 'required', selected: mode !== 'optional' })),
  ...requirements.not_scored.filter(s => s.leg === leg).map(s => ({
    ...s, required: false, group: group(s.scenario),
    selected: mode !== 'required' && (groups.includes('all') || groups.includes(group(s.scenario)))
  }))
];
if (new Set(inventory.map(s => s.scenario)).size !== inventory.length) throw Error('Duplicate scenario in requirements');
fs.writeFileSync(path.join(destination, 'selection.json'), JSON.stringify(inventory, null, 2) + '\n');
console.log(inventory.filter(s => s.selected).map(s => s.scenario).join('\n'));
SCENARIOS
    )
    printf 'Running %s %s scenarios for %s...\n' "$mode" "$leg" "$revision"
    suite_status=0
    : >"$destination/runner.log"
    : >"$destination/scenario-exit-codes.tsv"
    for scenario in $scenarios; do
      scenario_log="$destination/logs/$scenario.log"
      mkdir -p "$(dirname "$scenario_log")"
      printf '  %s\n' "$scenario"
      if node "$runner_dir/dist/index.js" "$leg" "${target[@]}" \
        --scenario "$scenario" --spec-version "$revision" --force \
        --timeout "$timeout_ms" --output-dir "$destination" \
        >"$scenario_log" 2>&1; then
        scenario_status=0
      else
        scenario_status=$?
        [[ "$scenario_status" -le "$suite_status" ]] || suite_status=$scenario_status
      fi
      printf '%s\t%s\n' "$scenario" "$scenario_status" >>"$destination/scenario-exit-codes.tsv"
      cat "$scenario_log" >>"$destination/runner.log"
    done
    printf '%s\n' "$suite_status" >"$destination/exit-code.txt"
  done
done

trap - ERR
node --input-type=module - "$runner_dir" "$results_dir" "$revisions" "$legs" "$mode" "$optional_groups" <<'JAVASCRIPT'
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
process.on('uncaughtException', error => { console.error(error); process.exit(2); });
const [runner, output, revisions, legs, mode, groupList] = process.argv.slice(2);
const { parse } = createRequire(path.join(runner, 'package.json'))('yaml');
const report = {
  sdkCommit: fs.readFileSync(path.join(output, 'sdk-commit.txt'), 'utf8').trim(),
  sdkWorkingTree: fs.readFileSync(path.join(output, 'sdk-working-tree.txt'), 'utf8').trim(),
  runnerCommit: fs.readFileSync(path.join(output, 'runner-commit.txt'), 'utf8').trim(),
  runnerVersion: JSON.parse(fs.readFileSync(path.join(runner, 'package.json'))).version,
  serverUrl: fs.readFileSync(path.join(output, 'server-url.txt'), 'utf8').trim(),
  serverModule: process.env.MCP_CONFORMANCE_SERVER_MODULE || 'conformance/server',
  mode,
  optionalGroups: groupList.trim().split(/\s+/),
  selection: `Mode: ${mode}. Optional groups: ${groupList}. Membership from the pinned official requirements.`,
  results: [],
};
function files(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? files(full) : entry.name === 'checks.json' ? [full] : [];
  });
}
function outcome(scenario) {
  if (scenario.failed > 0 || (scenario.exitCode !== null && scenario.exitCode !== 0)) return 'failed';
  if (scenario.missingResults) return 'unmeasured';
  if (scenario.exitCode === 0 && scenario.passed > 0) return 'passed';
  if (scenario.exitCode === 0 && scenario.skipped) return 'skipped';
  return 'unmeasured';
}
function totals(scenarios) {
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
for (const revision of revisions.trim().split(/\s+/)) {
  const requirements = parse(fs.readFileSync(path.join(runner, 'requirements', `${revision}.yaml`), 'utf8'));
  for (const leg of ['server', 'client']) {
    if (!legs.trim().split(/\s+/).includes(leg)) {
      report.results.push({ revision, leg, notRun: true, requiredScenarios: requirements[leg].length,
        reason: 'Role excluded by MCP_CONFORMANCE_LEGS.' });
      continue;
    }
    const directory = path.join(output, revision, leg);
    const exitCodes = new Map(fs.readFileSync(path.join(directory, 'scenario-exit-codes.tsv'), 'utf8')
      .trim().split('\n').filter(Boolean).map(line => {
        const [scenario, code] = line.split('\t');
        return [scenario, Number(code)];
      }));
    const recorded = new Map(files(directory).map(file => {
      const scenario = path.relative(directory, path.dirname(file))
        .replace(leg === 'server' ? /^server-/ : /$^/, '')
        .replace(/-\d{4}-\d{2}-\d{2}T.*$/, '');
      return [scenario, { file, checks: JSON.parse(fs.readFileSync(file, 'utf8')) }];
    }));
    const log = fs.readFileSync(path.join(directory, 'runner.log'), 'utf8').replace(/\x1b\[[0-9;]*m/g, '');
    const inventory = JSON.parse(fs.readFileSync(path.join(directory, 'selection.json'), 'utf8'));
    const scenarios = inventory.filter(s => s.selected).map(selection => {
      const { scenario } = selection;
      const record = recorded.get(scenario);
      const checks = record?.checks;
      let passed = checks?.filter(c => c.status === 'SUCCESS').length || 0;
      let failed = checks?.filter(c => c.status === 'FAILURE').length || 0;
      const exitCode = exitCodes.get(scenario) ?? null;
      let missingResults = !record || exitCode === null;
      if (!checks) {
        const line = log.split('\n').find(line => line.startsWith(`✓ ${scenario}: `) || line.startsWith(`✗ ${scenario}: `));
        const count = line?.match(/: (\d+) passed, (\d+) failed/);
        if (count) { passed = Number(count[1]); failed = Number(count[2]); missingResults = exitCode === null; }
      }
      return { scenario, required: selection.required, reason: selection.reason, group: selection.group || null,
        note: selection.note || null, exitCode, passed, failed,
        executionFailure: exitCode !== null && exitCode !== 0 ? `Official runner exited ${exitCode}; see logs/${scenario}.log.` : null,
        skippedChecks: checks?.filter(c => c.status === 'SKIPPED').length || 0,
        skippedDetails: checks?.filter(c => c.status === 'SKIPPED').map(c => ({ id: c.id, name: c.name, message: c.errorMessage || c.description })) || [],
        skipped: passed === 0 && failed === 0 && Boolean(checks?.some(c => c.status === 'SKIPPED')),
        missingResults,
        warnings: checks?.filter(c => c.status === 'WARNING').length || 0,
        checksFile: record ? path.relative(output, record.file) : null,
        failures: checks?.filter(c => c.status === 'FAILURE').map(c => ({ id: c.id, message: c.errorMessage || c.description })) || [] };
    });
    report.results.push({ revision, leg,
      exitCode: Number(fs.readFileSync(path.join(directory, 'exit-code.txt'), 'utf8')),
      requiredNotRun: mode === 'optional',
      optionalNotRun: mode === 'required',
      excludedScenarios: inventory.filter(s => !s.selected).map(({ selected, ...scenario }) => scenario),
      required: totals(scenarios.filter(s => s.required)),
      notScored: totals(scenarios.filter(s => !s.required)), all: totals(scenarios), scenarios });
  }
}
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
const measured = report.results.filter(r => !r.notRun);
report.totalRequired = totals(measured.flatMap(r => r.scenarios.filter(s => s.required)));
report.totalOptional = totals(measured.flatMap(r => r.scenarios.filter(s => !s.required)));
for (const [group, count, selected] of [['required', report.totalRequired, mode !== 'optional'], ['optional', report.totalOptional, mode !== 'required']]) {
  if (!selected) continue;
  lines.push('', `Total ${group} scenarios: ${count.scenariosPassed} passed, ${count.scenariosFailed} failed, ${count.scenariosSkipped} skipped, ${count.scenariosNotMeasured} unmeasured.`,
    `Total ${group} checks: ${count.checksPassed} passed, ${count.checksFailed} failed, ${count.checksSkipped} skipped.`);
}
fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify(report, null, 2) + '\n');
fs.writeFileSync(path.join(output, 'summary.txt'), lines.join('\n') + '\n');
console.log(lines.join('\n'));
console.log(`\nDetailed results: ${path.join(output, 'summary.json')}`);
process.exitCode = measured.some(r => r.all.missingResults > 0 || r.all.scenariosNotMeasured > 0 || r.required.scenariosSkipped > 0 || r.exitCode > 1) ? 2
  : measured.some(r => r.all.scenariosFailed > 0) ? 1 : 0;
JAVASCRIPT
