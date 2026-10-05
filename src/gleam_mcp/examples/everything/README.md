# Everything Server

A Gleam implementation of the [official Everything Reference Server 2.0.0](https://github.com/modelcontextprotocol/servers/tree/5abed86c5317b833dd59907492d56c65981642aa/src/everything), pinned to commit `5abed86c5317b833dd59907492d56c65981642aa`.

The example implements the reference tool schemas, annotations, results, four prompts, completions, two dynamic resource templates, and seven documentation resources. Generated gzip files belong to the creating session. Resource subscriptions, simulated logging and updates, roots refresh, progress notifications, research tasks, and client sampling/elicitation tasks share that session's lifecycle.

There are 12 base tools. After initialization the server makes these additional tools available according to client capabilities:

| Tool | Client capability |
| --- | --- |
| `simulate-research-query` | Available after initialization; requires task execution |
| `get-roots-list` | Roots |
| `trigger-sampling-request` | Sampling |
| `trigger-elicitation-request` | Elicitation |
| `trigger-url-elicitation` | URL elicitation |
| `trigger-sampling-request-async` | Sampling and task execution for sampling requests |
| `trigger-elicitation-request-async` | Elicitation and task execution for elicitation requests |

The reference's interactive behavior uses the `2025-11-25` protocol. The SDK also accepts its newer revision; this example exposes ordinary tools, prompts, resources, and progress there, while hiding examples that depend on legacy sessions or reverse JSON-RPC. Anonymous modern HTTP gzip links use an opaque URI; authenticated generated resources are scoped to the principal.

Run any of the reference transports:

```sh
gleam run -m gleam_mcp/examples/everything/main -- stdio
gleam run -m gleam_mcp/examples/everything/main -- streamableHttp
gleam run -m gleam_mcp/examples/everything/main -- sse
```

HTTP defaults to `PORT` or 3001. An optional final port argument overrides it. Streamable HTTP serves `/mcp`; deprecated SSE serves `/sse` and `/message`. The demonstration HTTP transports allow Inspector CORS, and legacy Streamable HTTP supports event IDs and `Last-Event-ID` replay. The SDK's default origin checks and modern stream behavior remain independent of the example's transport setup.

The gzip tool accepts data URIs and HTTP(S) URLs. Its fetch limits follow the reference environment variables:

- `GZIP_MAX_FETCH_SIZE`: maximum input bytes, default 10 MiB.
- `GZIP_MAX_FETCH_TIME_MILLIS`: fetch deadline, default 30000 ms.
- `GZIP_ALLOWED_DOMAINS`: comma-separated allowed domains and their subdomains; empty allows every domain.

Reproduce the comparisons against the pinned upstream server:

```sh
scripts/run-everything-parity.sh
```

The runner builds both servers and reports pass/fail counts with individual differences. It checks capability combinations, catalogs and schemas, outputs, completions, interactions, gzip payloads, notifications, task flows, and HTTP transport behavior. Reports and server logs are retained outside the repository; its downloaded checkout is removed on exit. Set `MCP_EVERYTHING_REFERENCE` to reuse an existing checkout of the pinned commit.

See [UPSTREAM.md](UPSTREAM.md) for documentation attribution and licensing. The mirrored documentation resources retain the official server's contents, including its TypeScript examples. Compression uses the published `gzlib` Gleam package; the gzip framing and example implementation are Gleam.
