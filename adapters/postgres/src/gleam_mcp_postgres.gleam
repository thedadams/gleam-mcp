//// PostgreSQL-backed session and task stores for gleam_mcp servers. Every
//// replica of a server can share one database, so sessions and tasks survive
//// restarts and any replica can serve any client.
////
//// ```gleam
//// let pool = process.new_name("mcp_db")
//// let assert Ok(config) = pog.url_config(pool, database_url)
//// // Start the pool under your supervisor with pog.supervised(config).
//// let db = pog.named_connection(pool)
//// let assert Ok(Nil) = gleam_mcp_postgres.migrate(db)
//// let stores = gleam_mcp_postgres.stores(db)
//// server.new(implementation)
//// |> server.with_session_store(stores.sessions)
//// |> server.with_task_store(stores.tasks)
//// ```

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/persistence.{type StoreError, StoreError}
import gleam_mcp/persistence/codec
import pog

pub type Stores {
  Stores(sessions: persistence.SessionStore, tasks: persistence.TaskStore)
}

const schema = [
  "CREATE TABLE IF NOT EXISTS mcp_sessions (
    id TEXT PRIMARY KEY,
    record TEXT NOT NULL,
    expires_at BIGINT NOT NULL
  )",
  "CREATE INDEX IF NOT EXISTS mcp_sessions_expires_at
    ON mcp_sessions (expires_at)",
  "CREATE TABLE IF NOT EXISTS mcp_resource_subscriptions (
    session_id TEXT NOT NULL REFERENCES mcp_sessions (id) ON DELETE CASCADE,
    uri TEXT NOT NULL,
    PRIMARY KEY (session_id, uri)
  )",
  "CREATE INDEX IF NOT EXISTS mcp_resource_subscriptions_uri
    ON mcp_resource_subscriptions (uri)",
  "CREATE TABLE IF NOT EXISTS mcp_tasks (
    id TEXT PRIMARY KEY,
    scope TEXT,
    record TEXT NOT NULL,
    version BIGINT NOT NULL,
    expires_at BIGINT
  )",
  "CREATE INDEX IF NOT EXISTS mcp_tasks_scope ON mcp_tasks (scope)",
  "CREATE INDEX IF NOT EXISTS mcp_tasks_expires_at ON mcp_tasks (expires_at)",
]

/// Create the tables the stores use, if they do not exist yet.
pub fn migrate(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  list.try_each(schema, fn(statement) {
    pog.query(statement) |> pog.execute(db) |> result.replace(Nil)
  })
}

pub fn stores(db: pog.Connection) -> Stores {
  Stores(sessions: sessions(db), tasks: tasks(db))
}

pub fn sessions(db: pog.Connection) -> persistence.SessionStore {
  persistence.SessionStore(
    put: fn(record) {
      pog.query(
        "INSERT INTO mcp_sessions (id, record, expires_at) VALUES ($1, $2, $3)
         ON CONFLICT (id) DO UPDATE
         SET record = EXCLUDED.record, expires_at = EXCLUDED.expires_at",
      )
      |> pog.parameter(pog.text(record.id))
      |> pog.parameter(pog.text(codec.encode_session(record)))
      |> pog.parameter(pog.int(codec.to_milliseconds(record.expires_at)))
      |> run(db)
    },
    get: fn(id) {
      pog.query("SELECT record FROM mcp_sessions WHERE id = $1")
      |> pog.parameter(pog.text(id))
      |> one(db, codec.decode_session)
    },
    delete: fn(id) {
      pog.query("DELETE FROM mcp_sessions WHERE id = $1")
      |> pog.parameter(pog.text(id))
      |> run(db)
    },
    set_subscription: fn(id, uri, enabled) {
      case enabled {
        True ->
          pog.query(
            "INSERT INTO mcp_resource_subscriptions (session_id, uri)
             VALUES ($1, $2) ON CONFLICT DO NOTHING",
          )
        False ->
          pog.query(
            "DELETE FROM mcp_resource_subscriptions
             WHERE session_id = $1 AND uri = $2",
          )
      }
      |> pog.parameter(pog.text(id))
      |> pog.parameter(pog.text(uri))
      |> run(db)
    },
    subscribers: fn(uri) {
      pog.query(
        "SELECT session_id FROM mcp_resource_subscriptions WHERE uri = $1",
      )
      |> pog.parameter(pog.text(uri))
      |> strings(db)
    },
    subscriptions: fn(id) {
      pog.query(
        "SELECT uri FROM mcp_resource_subscriptions WHERE session_id = $1",
      )
      |> pog.parameter(pog.text(id))
      |> strings(db)
    },
    delete_expired: fn(now) {
      pog.query("DELETE FROM mcp_sessions WHERE expires_at <= $1 RETURNING id")
      |> pog.parameter(pog.int(codec.to_milliseconds(now)))
      |> strings(db)
    },
  )
}

pub fn tasks(db: pog.Connection) -> persistence.TaskStore {
  persistence.TaskStore(
    insert: fn(record) {
      pog.query(
        "INSERT INTO mcp_tasks (id, scope, record, version, expires_at)
         VALUES ($1, $2, $3, $4, $5)",
      )
      |> task_parameters(record)
      |> run(db)
    },
    get: fn(id) {
      pog.query("SELECT record FROM mcp_tasks WHERE id = $1")
      |> pog.parameter(pog.text(id))
      |> one(db, codec.decode_task)
    },
    list: fn(scope) {
      case scope {
        persistence.AnyScope -> pog.query("SELECT record FROM mcp_tasks")
        persistence.Scope(scope) ->
          pog.query("SELECT record FROM mcp_tasks WHERE " <> scope_match)
          |> pog.parameter(pog.nullable(pog.text, scope))
      }
      |> many(db, codec.decode_task)
    },
    replace: fn(record) {
      pog.query(
        "UPDATE mcp_tasks
         SET scope = $2, record = $3, version = $4, expires_at = $5
         WHERE id = $1 AND version = $4 - 1",
      )
      |> task_parameters(record)
      |> pog.execute(db)
      |> result.map(fn(returned) { returned.count == 1 })
      |> result.map_error(store_error)
    },
    delete: fn(id) {
      pog.query("DELETE FROM mcp_tasks WHERE id = $1")
      |> pog.parameter(pog.text(id))
      |> run(db)
    },
    delete_scope: fn(scope) {
      pog.query(
        "DELETE FROM mcp_tasks WHERE " <> scope_match <> " RETURNING id",
      )
      |> pog.parameter(pog.nullable(pog.text, scope))
      |> strings(db)
    },
    delete_expired: fn(now) {
      pog.query("DELETE FROM mcp_tasks WHERE expires_at <= $1 RETURNING id")
      |> pog.parameter(pog.int(codec.to_milliseconds(now)))
      |> strings(db)
    },
  )
}

/// Matches tasks whose scope equals the first parameter, including tasks
/// without a scope when the parameter is null.
const scope_match = "scope IS NOT DISTINCT FROM $1"

fn task_parameters(
  query: pog.Query(Nil),
  record: persistence.TaskRecord,
) -> pog.Query(Nil) {
  query
  |> pog.parameter(pog.text(record.task.task_id))
  |> pog.parameter(pog.nullable(pog.text, record.scope))
  |> pog.parameter(pog.text(codec.encode_task(record)))
  |> pog.parameter(pog.int(record.version))
  |> pog.parameter(pog.nullable(
    pog.int,
    option.map(record.expires_at, codec.to_milliseconds),
  ))
}

fn run(query: pog.Query(Nil), db: pog.Connection) -> Result(Nil, StoreError) {
  pog.execute(query, db)
  |> result.replace(Nil)
  |> result.map_error(store_error)
}

fn strings(
  query: pog.Query(Nil),
  db: pog.Connection,
) -> Result(List(String), StoreError) {
  query
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(store_error)
}

fn many(
  query: pog.Query(Nil),
  db: pog.Connection,
  parse: fn(String) -> Result(a, String),
) -> Result(List(a), StoreError) {
  use rows <- result.try(strings(query, db))
  list.try_map(rows, fn(row) { parse(row) |> result.map_error(unreadable) })
}

fn one(
  query: pog.Query(Nil),
  db: pog.Connection,
  parse: fn(String) -> Result(a, String),
) -> Result(Option(a), StoreError) {
  use rows <- result.map(many(query, db, parse))
  case rows {
    [row, ..] -> Some(row)
    [] -> None
  }
}

fn unreadable(message: String) -> StoreError {
  StoreError("Stored record is unreadable: " <> message)
}

fn store_error(error: pog.QueryError) -> StoreError {
  StoreError(case error {
    pog.ConnectionUnavailable -> "Database connection unavailable"
    pog.QueryTimeout -> "Database query timed out"
    pog.PostgresqlError(_, name, message) -> name <> ": " <> message
    pog.ConstraintViolated(message, _, _) -> message
    other -> string.inspect(other)
  })
}
