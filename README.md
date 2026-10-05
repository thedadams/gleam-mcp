# gleam-mcp

[![Tests](https://github.com/thedadams/gleam-mcp/actions/workflows/tests.yml/badge.svg)](https://github.com/thedadams/gleam-mcp/actions/workflows/tests.yml)

An MCP SDK for Gleam on Erlang, targeting protocol version **2025-11-25**.

The client and server support Streamable HTTP and bidirectional stdio, typed
requests and notifications, sampling (including tool use), form and URL
elicitation, and task-augmented requests. Initialization records negotiated
capabilities and gates optional operations. JSON-RPC decoding checks the
envelope and response IDs, and preserves extension metadata.

HTTP requests consume JSON or SSE incrementally. The client retains SSE cursors
and retry delays, uses a deadline across reconnects, and can reinitialize an
expired session without repeating the failed operation. The server validates
Origin and protocol headers, binds sessions and tasks to authenticated identities,
supports multiple streams, and releases sessions through DELETE.

Task workers support cancellation, real timestamps, finite TTL expiry, and
terminal result delivery. Task storage is in memory. Resource subscriptions,
descriptor registration, capability configuration, pagination, progress, request
timeouts, and explicit transport shutdown are available through the public API.

Configure accepted browser origins with `server.with_allowed_origins`; browser
deployments also need CORS at their HTTP hosting layer.
Use `server.with_identity_authorization` to validate a header and return a stable
application identity, or `server.with_oauth_authorization` for OAuth resource
metadata, Bearer challenges, and issuer/audience/expiry/scope checks.
The low-level stateless `server.handle_request` API is trusted application access;
transport adapters apply session lifecycle and ownership checks.

The `gleam_mcp/client/oauth` module uses `flwr_oauth2` for OAuth requests and token
responses. It supports protected-resource and OAuth/OIDC issuer discovery, PKCE
with S256, authorization-code exchange, refresh, and resource-bound Bearer
configuration. Applications open the authorization URL, handle the redirect,
and securely store tokens. A server supplies a token verifier that authenticates
the issuer's token signature or introspection response before returning verified
claims; the SDK then enforces its configured resource and permissions.

General JSON Schema 2020-12 validation remains unimplemented. Tool handlers must
validate their inputs and outputs. The HTTP server does not retain SSE event
history for replay.

## Roadmap
- [x] Basic client functionality for Streamable HTTP
- [x] Basic client functionality for Stdio, including running a process and sending/receiving messages
- [x] Server functionality for Streamable HTTP, including tasks
- [x] Bidirectional server functionality for STDIO, including tasks
- [x] Task support for servers
- [x] Task support for clients
- [x] OAuth support for Streamable HTTP clients
- [x] OAuth support for Streamable HTTP servers
- [x] Support for server sent requests for Streamable HTTP
- [x] Support for server sent requests for STDIO
- [x] Support for cancellation in both directions
- [x] Restart HTTP GET for server-sent requests
- [x] Convenience functions for processing requests and responses
- [x] Separate client and server requests and responses
- [x] Distinguish missing and invalid HTTP session IDs
- [ ] General JSON Schema 2020-12 validation
- [ ] Server SSE event replay
- [ ] Durable task storage

## OAuth

Create a client OAuth configuration with `oauth.new(resource_url, client_id,
redirect_uri)`. Use `oauth.discover_from_server` to discover the resource and its
issuer, then `oauth.begin` to create an authorization URL. After the application
receives the redirect, pass its complete URI to `oauth.exchange_from_redirect`,
which checks the redirect, state, and authorization-server issuer. Apply the
returned tokens with `oauth.authorize_http` before creating the MCP client. Use
`oauth.refresh` when needed. Discovery and token functions also accept an
application-supplied HTTP sender through their `_with_sender` variants.
Transport `AuthorizationRequired` errors retain the server's challenge for
scope selection and a new authorization attempt; failed operations are not
automatically repeated.

For a server, create `gleam_mcp/server/oauth.new(resource_url,
authorization_servers, required_scopes, verifier)` and apply the result with
`server.with_oauth_authorization`. Its HTTP handler serves the resource's
`/.well-known/oauth-protected-resource` path and returns scope-aware challenges.
The verifier returns `VerifiedToken` only after authenticating the token; simply
decoding JWT claims is insufficient. Token issuance and authorization-server
hosting belong to the selected OAuth provider.

## Testing

Run `gleam test` and `gleam format --check src test`. Local wire tests exercise
both transports. Set `MCP_EVERYTHING_URL`, `MCP_EVERYTHING_STDIO_COMMAND`, and
`MCP_EVERYTHING_STDIO_ARGS` to also run the official Everything server
interoperability tests; CI supplies these values.
