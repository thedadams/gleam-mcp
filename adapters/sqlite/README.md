# gleam_mcp_sqlite

SQLite session and task stores for a `gleam_mcp` server, so its sessions and
tasks survive restarts.

The database is a file on one machine, so these stores suit a **single
replica**. Do not share the file between replicas, including over a network
volume; use `gleam_mcp_postgres` to run several.

```gleam
import gleam/erlang/process
import gleam_mcp/server
import gleam_mcp_sqlite

let db = process.new_name("mcp_sqlite")
// Start it under your supervisor with
// gleam_mcp_sqlite.supervised(db, "mcp.sqlite3").
let stores = gleam_mcp_sqlite.stores(db)

server.new(implementation)
|> server.with_session_store(stores.sessions)
|> server.with_task_store(stores.tasks)
```

The database process creates its tables on start and serialises access to the
connection. `sqlight` builds SQLite from C, so building needs a C compiler.
