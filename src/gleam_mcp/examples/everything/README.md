# Everything Server

This directory contains a best-effort Gleam port of the MCP reference `everything` server.

Implemented here:
- tools for echo, sum, env inspection, structured content, images, annotations, resource links, and embedded resources
- stdio-only server-initiated tools for sampling and elicitation roundtrips
- static resources and dynamic text/blob resource templates
- prompts, including argument-driven prompts and completion support
- stdio and basic streamable HTTP entrypoints

Not implemented yet because the current public SDK does not expose the needed server hooks:
- resource subscriptions and update notifications
- simulated logging notifications
- roots synchronization
- server-initiated sampling and elicitation requests over streamable HTTP
- faithful long-running and bidirectional task flows

Run with stdio:

```sh
gleam run -m everything/main
```

Run with streamable HTTP on port 3000:

```sh
gleam run -m everything/main -- streamableHttp 3000
```
