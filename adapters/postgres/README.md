# gleam_mcp_postgres

PostgreSQL session and task stores for `gleam_mcp` servers. Every replica of a
server can share one database, so sessions and tasks survive restarts and any
replica can serve any client.

```gleam
import gleam/erlang/process
import gleam_mcp/server
import gleam_mcp_postgres
import pog

let pool = process.new_name("mcp_db")
let assert Ok(config) = pog.url_config(pool, database_url)
// Start the pool under your supervisor with pog.supervised(config).
let db = pog.named_connection(pool)
let assert Ok(Nil) = gleam_mcp_postgres.migrate(db)
let stores = gleam_mcp_postgres.stores(db)

server.new(implementation)
|> server.with_session_store(stores.sessions)
|> server.with_task_store(stores.tasks)
```

`migrate` creates the `mcp_sessions`, `mcp_resource_subscriptions` and
`mcp_tasks` tables if they do not exist. To run several replicas, also give
them the same request state secret and cluster name; see the `gleam_mcp`
README.

Tests run against the database in `DATABASE_URL` and are skipped without it:

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres gleam test
```
