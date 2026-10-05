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
    scenarios=$(node "$repo_dir/scripts/conformance/select.mjs" \
      "$runner_dir" "$revision" "$leg" "$mode" "$optional_groups" "$destination")
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
node "$repo_dir/scripts/conformance/report.mjs" \
  "$runner_dir" "$results_dir" "$revisions" "$legs" "$mode" "$optional_groups"
