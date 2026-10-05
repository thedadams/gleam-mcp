# gleam-mcp

[![Tests](https://github.com/thedadams/gleam-mcp/actions/workflows/tests.yml/badge.svg)](https://github.com/thedadams/gleam-mcp/actions/workflows/tests.yml)

An MCP SDK for Gleam on Erlang, supporting **2026-07-28** and **2025-11-25**.

The client and server support Streamable HTTP and stdio, typed tools, resources,
prompts, completion, sampling, roots, and form and URL elicitation. JSON-RPC
boundaries validate envelopes and response IDs and preserve application metadata.

## Connecting

Use `client.connect(client, client_info)` for discovery and automatic fallback
when a peer demonstrates legacy behavior. Its connection information is either
`client.Modern(DiscoverResult)` or `client.Legacy(InitializeResult)`. Authentication
failures, server failures, and invalid successful HTTP responses fail discovery.
Use `client.with_protocol_version(client, "2026-07-28")` to require the modern
protocol, or pin `"2025-11-25"` to skip discovery. The existing
`client.initialize(client, client_info)` explicitly uses the 2025 handshake.

Modern requests carry protocol version, client capabilities, and client identity
in `_meta`. There is no initialization handshake or MCP session ID. HTTP uses a
single POST exchange, consuming JSON or SSE incrementally. Cancellation closes
that request's stream; a broken stream is reported to the caller. Modern requests
do not use GET listeners, event cursors, or automatic stream replay.

The legacy path retains initialization, session ownership, GET listeners, SSE
reconnection, reverse requests, and task-augmented requests. An expired legacy
session can be reinitialized without repeating the failed operation.

## Modern protocol features

The client fulfils `input_required` results through the existing sampling, roots,
and elicitation callbacks, then retries the original operation with a fresh ID.
Each retry replaces the previous input responses and echoes the opaque request
state. `client.with_maximum_input_rounds` bounds the continuation loop; request
timeouts also bound it.

Servers use `server.with_modern_request_handler` for `tools/call`, `resources/read`,
and `prompts/get` operations that require client input. Its callback receives
`(server, context, action)` and returns a `Result(ClientActionResult, RpcError)`.
Return `actions.ClientResultInputRequired(actions.InputRequiredResult(inputs,
state, meta))`, with at least one of `inputs` or `state` present. `inputs` is an
optional dictionary of identifiers to bare `{method, params}` input requests;
`state` is an optional opaque string. On retry, read `actions.input_responses(action)`
and `actions.request_state(action)`; use `actions.request_without_input(action)`
to inspect the original operation. Responses are bare sampling, roots, or
elicitation results keyed by the same identifiers. Use
`server.sign_request_state` and `server.verify_request_state` to protect state
that controls application decisions. Multiple server instances can share a key
through `server.with_request_state_secret`.

Modern subscriptions use `subscriptions/listen` and an acknowledgement before
change events. `client.listen(client)` selects list-change notifications from its
configured callbacks. Use `client.listen_with_notifications(client, Some(filter))`
to select resource URIs or task IDs explicitly, for example:

```gleam
let filter = jsonrpc.VObject([
  #("toolsListChanged", jsonrpc.VBool(True)),
  #("resourceSubscriptions", jsonrpc.VArray([
    jsonrpc.VString("file:///projects/readme.md"),
  ])),
])
let #(next_client, outcome) =
  client.listen_with_notifications(connected_client, Some(filter))
```

Listening blocks until the stream completes or the client closes; another
process can call `client.close` to stop it. Events invoke the configured
notification callbacks and carry the listen request's subscription ID. Register
`capabilities.with_subscription_acknowledged` to receive the effective filter.
Servers publish changes with `server.publish_notification`. Progress and logging
stay on the individual request stream. `client.with_log_level` opts into request
logs; without a level,
modern servers suppress them.

The optional `io.modelcontextprotocol/tasks` extension supplies task handles and
nonblocking `tasks/get`, `tasks/update`, and `tasks/cancel`. The 2025 core methods
`tasks/list` and `tasks/result` are unavailable in the modern protocol. Task
workers support cancellation, expiry, owner isolation, and input continuations.
Storage remains in memory.
Use `client.with_tasks_extension` to advertise it and `client.get_task_modern`,
`client.update_task`, and `client.cancel_task_modern` for its operations.
Both client and server expose `with_extensions` for additional capability maps.

For custom asynchronous operations, call
`server.create_modern_task(server, context, ttl_ms, worker)`. It requires the tasks
extension on both sides and returns a `Result(ClientActionResult, RpcError)` whose
successful value is a `ClientResultTaskModern` handle. `ttl_ms` is an `Option(Int)`
in milliseconds. The worker returns `Result(task_store.ModernOutcome, RpcError)`:
`ModernComplete(value)` stores the original operation's result object; use
`wire.result_value` to serialize a typed result.
`ModernInputRequired(inputs, resume)` pauses until the requested input identifiers
have been answered. `resume` receives a dictionary of bare input responses and
can complete or request another round of input. Capture
`server.modern_task_context(context)` for worker callbacks to retain caller
identity while dropping the initiating request's progress and logging stream.

The modern client task methods return `jsonrpc.Value`. Poll `get_task_modern` for
status and the completed `result` or failed `error`. When a task reports
`input_required`, answer its `inputRequests` and submit the matching dictionary
with `client.update_task(client, task_id, input_responses)`. Unlike synchronous
MRTR operations, task input collection and polling are application-controlled.

Cacheable modern responses include `ttlMs` and `cacheScope`, defaulting to zero
and `private`. Return `actions.ClientResultWithCache` to supply an explicit hint.
The client exposes the most recent hint with `client.last_cache_hint`; application
code decides whether and where to cache responses.

HTTP mirrors method, protocol version, and the relevant name or URI in request
headers. Tool schema `x-mcp-header` annotations produce `Mcp-Param-*` headers;
Unicode, whitespace, and unsafe bytes use the specified Base64 sentinel. The
server checks header/body agreement and excludes invalid annotated tools from
HTTP listings. Tool `structured_content` accepts any `jsonrpc.Value`, including
arrays, scalars, and explicit null.

## Authorization

Configure accepted browser origins with `server.with_allowed_origins`. Browser
hosting also needs CORS. Use `server.with_identity_authorization` to authenticate
a header and return a stable application identity, or
`server.with_oauth_authorization` for protected-resource metadata and verified
issuer, audience, expiry, and scope checks. Transport adapters authenticate each
modern request. Direct `server.handle_request` calls are trusted application
access.

The `gleam_mcp/client/oauth` module uses `flwr_oauth2` for OAuth requests and token
responses. It supports protected-resource and OAuth/OIDC issuer discovery, PKCE
S256, code exchange, refresh, and resource-bound Bearer configuration.

Create a configuration with `oauth.new(resource_url, client_id, redirect_uri)`.
Pre-registered credentials must be bound to their issuing authorization server
with `oauth.with_issuer(config, issuer)` before beginning authorization. Selecting
a different issuer does not rebind existing credentials. Persist credentials
under `oauth.credentials_issuer(config)` and never reuse them with another issuer.

For a portable public client, use an HTTPS Client ID Metadata Document URL and
`oauth.with_client_metadata_document`. `oauth.client_metadata_document` generates
a document with the matching client ID, name, and redirect URI. The issuer must
advertise support for these documents. Dynamic client registration is not
implemented.

Use `oauth.discover_from_server`, then `oauth.begin` to obtain the authorization
URL. The application opens it and passes the complete callback URI to
`oauth.exchange_from_redirect`, which checks the redirect, state, and any
returned issuer before code exchange. Apply tokens through `oauth.authorize_http`
and securely store them. Use `oauth.refresh` when needed. Discovery and token
functions accept application HTTP senders through their `_with_sender` variants.
Authorization challenges retain scope information for reauthorization; failed
operations are not automatically repeated.

A server's OAuth verifier authenticates token signatures or introspection before
returning `VerifiedToken`; the SDK then enforces its configured resource and
permissions. Authorization-server hosting belongs to the selected provider.

## Validation and testing

General JSON Schema 2020-12 validation remains an outstanding limitation. Tool
handlers must validate their input and output values. The SDK preserves arbitrary
schema objects and does not fetch external `$ref` URLs. Legacy HTTP SSE event
history is not retained for replay.

Run `gleam check`, `gleam test`, and `gleam format --check src test`. Local tests
cover both protocol versions and transports.

Run `scripts/run-conformance.sh` to exercise the dedicated server and client in
`test/conformance` against the official MCP conformance runner. By default it runs
the required scenarios for both supported revisions, using a pinned runner commit.
The script starts the Gleam server, launches the Gleam client for each scenario,
and saves raw results and pass/fail summaries outside the repository. It needs
Bash, Git, Node.js 20 or later, npm, Gleam, curl, and pgrep.

The selection and reporting helpers in `scripts/conformance` have independent
tests: run `node --test scripts/conformance/*.test.mjs` without downloading the
official runner.

Use `scripts/run-conformance.sh --mode optional` for schema preservation, HTTP
header validation, and the tasks extension. Use `--mode all` to run both required
and selected optional scenarios. The reports keep the required score and optional
results separate, include the official unscored reason, and identify excluded
scenarios. An upstream optional skip remains visible without failing the run.

`MCP_CONFORMANCE_OPTIONAL_GROUPS` selects space-separated groups; its default is
`schema headers tasks`. Groups `auth`, `legacy`, and `other` are also available for
broader gap reports; `all` selects every official unscored scenario. Schema
coverage checks keyword preservation through the SDK, while general JSON Schema
validation remains separate work.

Use `scripts/run-conformance.sh --help` for output-directory and runner overrides.
Set `MCP_CONFORMANCE_LEGS=server` or `client` to select one role, or
`MCP_CONFORMANCE_REVISIONS=2026-07-28` to select one revision. Exit status 1 means
a selected scenario failed; status 2 means setup failed or results are incomplete.

Optional official SDK compatibility tests use these environment variables:

- `MCP_EVERYTHING_URL`, `MCP_EVERYTHING_STDIO_COMMAND`, and
  `MCP_EVERYTHING_STDIO_ARGS` for the legacy Everything server.
- `MCP_2026_URL`, `MCP_2026_STDIO_COMMAND`, and `MCP_2026_STDIO_ARGS` for the July
  SDK fixture in `test/fixtures/mcp_2026_server.mjs`.
- `MCP_2026_CLIENT_SCRIPT` for the official SDK client fixture talking to the Gleam
  HTTP server.

CI installs pinned official SDK versions and exercises both compatibility paths.
