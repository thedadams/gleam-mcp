//// SQLite-backed session and task stores for a gleam_mcp server, so its
//// sessions and tasks survive restarts.
////
//// The database is a file on one machine, so these stores suit a single
//// replica. Do not share the file between replicas, including over a network
//// volume; use gleam_mcp_postgres to run several replicas.
////
//// ```gleam
//// let db = process.new_name("mcp_sqlite")
//// // Start it under your supervisor with
//// // gleam_mcp_sqlite.supervised(db, "mcp.sqlite3").
//// let stores = gleam_mcp_sqlite.stores(db)
//// server.new(implementation)
//// |> server.with_session_store(stores.sessions)
//// |> server.with_task_store(stores.tasks)
//// ```

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam_mcp/persistence.{type StoreError, StoreError}
import gleam_mcp/persistence/codec
import sqlight

pub type Stores {
  Stores(sessions: persistence.SessionStore, tasks: persistence.TaskStore)
}

/// A request to run against the connection the store's process owns.
pub opaque type Message {
  Run(fn(sqlight.Connection) -> Nil)
}

const timeout_ms = 5000

const schema =
  "
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;
  PRAGMA busy_timeout = 5000;
  CREATE TABLE IF NOT EXISTS mcp_sessions (
    id TEXT PRIMARY KEY,
    record TEXT NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS mcp_sessions_expires_at
    ON mcp_sessions (expires_at);
  CREATE TABLE IF NOT EXISTS mcp_resource_subscriptions (
    session_id TEXT NOT NULL REFERENCES mcp_sessions (id) ON DELETE CASCADE,
    uri TEXT NOT NULL,
    PRIMARY KEY (session_id, uri)
  );
  CREATE INDEX IF NOT EXISTS mcp_resource_subscriptions_uri
    ON mcp_resource_subscriptions (uri);
  CREATE TABLE IF NOT EXISTS mcp_tasks (
    id TEXT PRIMARY KEY,
    scope TEXT,
    record TEXT NOT NULL,
    version INTEGER NOT NULL,
    expires_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS mcp_tasks_scope ON mcp_tasks (scope);
  CREATE INDEX IF NOT EXISTS mcp_tasks_expires_at ON mcp_tasks (expires_at);
"

/// Open the database at `path`, creating its tables if needed, in a process
/// registered under `name` that serialises access to it.
pub fn start(
  name: process.Name(Message),
  path: String,
) -> actor.StartResult(Stores) {
  actor.new_with_initialiser(timeout_ms, fn(_) {
    use connection <- result.try(
      sqlight.open(path) |> result.map_error(fn(error) { error.message }),
    )
    use _ <- result.try(
      sqlight.exec(schema, connection)
      |> result.map_error(fn(error) { error.message }),
    )
    actor.initialised(connection) |> actor.returning(stores(name)) |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(fn(connection, message) {
    case message {
      Run(work) -> {
        work(connection)
        actor.continue(connection)
      }
    }
  })
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  path: String,
) -> supervision.ChildSpecification(Stores) {
  supervision.worker(fn() { start(name, path) })
}

/// The stores of the database process registered under `name`.
pub fn stores(name: process.Name(Message)) -> Stores {
  Stores(sessions: sessions(name), tasks: tasks(name))
}

pub fn sessions(name: process.Name(Message)) -> persistence.SessionStore {
  persistence.SessionStore(
    put: fn(record) {
      run(
        name,
        "INSERT INTO mcp_sessions (id, record, expires_at) VALUES (?, ?, ?)
         ON CONFLICT (id) DO UPDATE
         SET record = excluded.record, expires_at = excluded.expires_at",
        [
          sqlight.text(record.id),
          sqlight.text(codec.encode_session(record)),
          sqlight.int(codec.to_milliseconds(record.expires_at)),
        ],
      )
    },
    get: fn(id) {
      one(
        name,
        "SELECT record FROM mcp_sessions WHERE id = ?",
        [sqlight.text(id)],
        codec.decode_session,
      )
    },
    delete: fn(id) {
      run(name, "DELETE FROM mcp_sessions WHERE id = ?", [sqlight.text(id)])
    },
    set_subscription: fn(id, uri, enabled) {
      let sql = case enabled {
        True ->
          "INSERT INTO mcp_resource_subscriptions (session_id, uri)
           VALUES (?, ?) ON CONFLICT DO NOTHING"
        False ->
          "DELETE FROM mcp_resource_subscriptions
           WHERE session_id = ? AND uri = ?"
      }
      run(name, sql, [sqlight.text(id), sqlight.text(uri)])
    },
    subscribers: fn(uri) {
      strings(
        name,
        "SELECT session_id FROM mcp_resource_subscriptions WHERE uri = ?",
        [sqlight.text(uri)],
      )
    },
    subscriptions: fn(id) {
      strings(
        name,
        "SELECT uri FROM mcp_resource_subscriptions WHERE session_id = ?",
        [sqlight.text(id)],
      )
    },
    delete_expired: fn(now) {
      strings(
        name,
        "DELETE FROM mcp_sessions WHERE expires_at <= ? RETURNING id",
        [sqlight.int(codec.to_milliseconds(now))],
      )
    },
  )
}

pub fn tasks(name: process.Name(Message)) -> persistence.TaskStore {
  persistence.TaskStore(
    insert: fn(record) {
      run(
        name,
        "INSERT INTO mcp_tasks (id, scope, record, version, expires_at)
         VALUES (?, ?, ?, ?, ?)",
        task_parameters(record),
      )
    },
    get: fn(id) {
      one(
        name,
        "SELECT record FROM mcp_tasks WHERE id = ?",
        [sqlight.text(id)],
        codec.decode_task,
      )
    },
    list: fn(scope) {
      case scope {
        persistence.AnyScope ->
          many(name, "SELECT record FROM mcp_tasks", [], codec.decode_task)
        persistence.Scope(scope) ->
          many(
            name,
            "SELECT record FROM mcp_tasks WHERE scope IS ?",
            [sqlight.nullable(sqlight.text, scope)],
            codec.decode_task,
          )
      }
    },
    replace: fn(record) {
      let assert [id, scope, data, version, expires_at] =
        task_parameters(record)
      strings(
        name,
        "UPDATE mcp_tasks SET scope = ?, record = ?, version = ?, expires_at = ?
         WHERE id = ? AND version = ? RETURNING id",
        [scope, data, version, expires_at, id, sqlight.int(record.version - 1)],
      )
      |> result.map(fn(ids) { ids != [] })
    },
    delete: fn(id) {
      run(name, "DELETE FROM mcp_tasks WHERE id = ?", [sqlight.text(id)])
    },
    delete_scope: fn(scope) {
      strings(name, "DELETE FROM mcp_tasks WHERE scope IS ? RETURNING id", [
        sqlight.nullable(sqlight.text, scope),
      ])
    },
    delete_expired: fn(now) {
      strings(name, "DELETE FROM mcp_tasks WHERE expires_at <= ? RETURNING id", [
        sqlight.int(codec.to_milliseconds(now)),
      ])
    },
  )
}

fn task_parameters(record: persistence.TaskRecord) -> List(sqlight.Value) {
  [
    sqlight.text(record.task.task_id),
    sqlight.nullable(sqlight.text, record.scope),
    sqlight.text(codec.encode_task(record)),
    sqlight.int(record.version),
    sqlight.nullable(
      sqlight.int,
      option.map(record.expires_at, codec.to_milliseconds),
    ),
  ]
}

fn run(
  name: process.Name(Message),
  sql: String,
  arguments: List(sqlight.Value),
) -> Result(Nil, StoreError) {
  query(name, sql, arguments, decode.success(Nil)) |> result.replace(Nil)
}

fn strings(
  name: process.Name(Message),
  sql: String,
  arguments: List(sqlight.Value),
) -> Result(List(String), StoreError) {
  query(name, sql, arguments, decode.at([0], decode.string))
}

fn many(
  name: process.Name(Message),
  sql: String,
  arguments: List(sqlight.Value),
  parse: fn(String) -> Result(a, String),
) -> Result(List(a), StoreError) {
  use rows <- result.try(strings(name, sql, arguments))
  list.try_map(rows, fn(row) {
    parse(row)
    |> result.map_error(fn(message) {
      StoreError("Stored record is unreadable: " <> message)
    })
  })
}

fn one(
  name: process.Name(Message),
  sql: String,
  arguments: List(sqlight.Value),
  parse: fn(String) -> Result(a, String),
) -> Result(Option(a), StoreError) {
  use rows <- result.map(many(name, sql, arguments, parse))
  case rows {
    [row, ..] -> Some(row)
    [] -> None
  }
}

/// Run a query in the process that owns the connection.
fn query(
  name: process.Name(Message),
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
) -> Result(List(a), StoreError) {
  case process.named(name) {
    Error(Nil) -> Error(StoreError("SQLite store is not running"))
    Ok(_) -> {
      let reply = process.new_subject()
      process.send(
        process.named_subject(name),
        Run(fn(connection) {
          process.send(
            reply,
            sqlight.query(sql, connection, arguments, decoder)
              |> result.map_error(fn(error) { StoreError(error.message) }),
          )
        }),
      )
      process.receive(reply, timeout_ms)
      |> result.replace_error(StoreError("SQLite store timed out"))
      |> result.flatten
    }
  }
}
