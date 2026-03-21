# gleam-mcp

[![Tests](https://github.com/thedadams/gleam-mcp/actions/workflows/tests.yml/badge.svg)](https://github.com/thedadams/gleam-mcp/actions/workflows/tests.yml)

This repository is a work in progress.

## Roadmap
- [x] Basic client functionality for Streamable HTTP
- [x] Basic client functionality for Stdio, including running a process and sending/receiving messages
- [x] Basic server functionality for Streamable HTTP, excluding tasks
- [x] Basic server functionality for STDIO, excluding tasks
- [x] Task support for servers
- [x] Task support for clients
- [ ] OAuth support for Streamable HTTP clients
- [ ] OAuth support for Streamable HTTP servers
- [x] Support for server sent requests for Streamable HTTP
- [x] Support for server sent requests for STDIO
- [ ] Support for cancellation in both directions
- [ ] Restart HTTP GET for server-sent requests
- [ ] Convenience functions for processing requests and responses
- [ ] Separate ActionRequests into client and server requests, and ActionResponses into client and server responses
- [ ] Ensure proper errors are returned from the streamable HTTP server when the session ID is not sent with non-initialization requests, and when the session ID is invalid
