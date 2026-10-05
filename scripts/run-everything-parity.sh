#!/usr/bin/env bash
# Compare the Gleam Everything example with a pinned official reference server.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'HELP'
Usage: scripts/run-everything-parity.sh [RESULTS_DIRECTORY]

Builds both Everything servers and compares their legacy MCP stdio behavior.
Then verifies Gleam Streamable HTTP, modern stateless HTTP and deprecated SSE
using the official SDK client and raw HTTP checks. Differences fail the run;
no expected-failure baseline is applied. Reports and server stderr are retained
in RESULTS_DIRECTORY. HTTP subprocess cleanup requires a POSIX host.

Environment overrides:
  MCP_EVERYTHING_REFERENCE  Existing official servers checkout at the pinned SHA
  MCP_EVERYTHING_TIMEOUT_MS Per-operation timeout (default: 20000)

The default checkout is temporary and removed on exit. An existing checkout is
never removed; its HEAD must match the pinned commit. Requires Bash, Git, Node.js
>=20, npm and Gleam. The runner records SHA, dependency versions and SDK changes.
HELP
  exit 0
fi
[[ $# -le 1 ]] || { printf 'Use --help for usage.\n' >&2; exit 2; }
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
reference_sha=5abed86c5317b833dd59907492d56c65981642aa
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/gleam-mcp-everything-parity-tools.XXXXXX")
results_dir=${1:-$(mktemp -d "${TMPDIR:-/tmp}/gleam-mcp-everything-parity-results.XXXXXX")}
mkdir -p -- "$results_dir"
results_dir=$(cd -- "$results_dir" && pwd)
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Everything parity setup failed near line %s; see %s\n" "$LINENO" "$results_dir" >&2; exit 2' ERR
[[ -z $(ls -A "$results_dir") ]] || {
  printf 'Results directory must be empty: %s\n' "$results_dir" >&2; exit 2
}
for dependency in git node npm gleam; do
  command -v "$dependency" >/dev/null || {
    printf 'Missing dependency: %s\n' "$dependency" >&2; exit 2
  }
done
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(2)'
timeout_ms=${MCP_EVERYTHING_TIMEOUT_MS:-20000}
[[ "$timeout_ms" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid timeout.\n' >&2; exit 2; }
reference_dir=${MCP_EVERYTHING_REFERENCE:-$work_dir/reference}
if [[ -z ${MCP_EVERYTHING_REFERENCE:-} ]]; then
  git init -q "$reference_dir"
  git -C "$reference_dir" remote add origin https://github.com/modelcontextprotocol/servers.git
  git -C "$reference_dir" fetch -q --depth 1 origin "$reference_sha"
  git -C "$reference_dir" checkout -q --detach FETCH_HEAD
  (cd "$reference_dir" && npm ci --workspace @modelcontextprotocol/server-everything --include-workspace-root=false --ignore-scripts --no-audit --no-fund) >"$results_dir/reference-install.log" 2>&1
fi
reference_dir=$(cd -- "$reference_dir" && pwd)
actual_sha=$(git -C "$reference_dir" rev-parse HEAD)
[[ "$actual_sha" == "$reference_sha" ]] || {
  printf 'Reference HEAD %s does not match pinned SHA %s.\n' "$actual_sha" "$reference_sha" >&2; exit 2
}
git -C "$reference_dir" diff --quiet HEAD -- src/everything || {
  printf 'Reference Everything source has local changes; refusing a modified baseline.\n' >&2; exit 2
}
printf '%s\n' "$actual_sha" >"$results_dir/reference-commit.txt"
git -C "$reference_dir" status --porcelain >"$results_dir/reference-working-tree.txt"
git -C "$repo_dir" rev-parse HEAD >"$results_dir/sdk-commit.txt"
git -C "$repo_dir" status --porcelain >"$results_dir/sdk-working-tree.txt"
(cd "$reference_dir" && npm run build --workspace @modelcontextprotocol/server-everything) >"$results_dir/reference-build.log" 2>&1
(cd "$repo_dir" && gleam build) >"$results_dir/sdk-build.log" 2>&1
printf 'Everything stdio parity against %s; results: %s\n' "$reference_sha" "$results_dir"
if node "$repo_dir/scripts/everything/parity.mjs" "$repo_dir" "$reference_dir" "$results_dir" "$timeout_ms"; then
  stdio_status=0
else
  stdio_status=$?
fi
printf 'Everything HTTP/SSE integration checks; results: %s\n' "$results_dir"
if node "$repo_dir/scripts/everything/http.mjs" "$repo_dir" "$reference_dir" "$results_dir" "$timeout_ms"; then
  http_status=0
else
  http_status=$?
fi
if node "$repo_dir/scripts/everything/report.mjs" "$results_dir" "$stdio_status" "$http_status"; then
  status=0
else
  status=$?
fi
exit "$status"
