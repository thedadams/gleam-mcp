//// Durable state shared by every replica of a server. A server keeps live
//// connections and workers in its own processes; everything another replica
//// must be able to read after this one restarts goes through these stores.
////
//// Both stores are records of functions so that an application can back them
//// with any database. In-memory implementations live in
//// `gleam_mcp/persistence/memory` and are used when nothing else is configured.

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import gleam_mcp/actions
import gleam_mcp/jsonrpc

/// A failure in the backing store, such as a lost database connection.
pub type StoreError {
  StoreError(message: String)
}

/// What a 2025-11-25 session negotiated during initialisation, and the
/// authenticated user it belongs to.
pub type SessionMetadata {
  SessionMetadata(
    protocol_version: String,
    client_capabilities: actions.ClientCapabilities,
    initialized: Bool,
    ready: Bool,
    principal: Option(String),
  )
}

/// A session allocated by the transport. Metadata is absent until the session
/// is bound to its caller.
pub type SessionRecord {
  SessionRecord(
    id: String,
    metadata: Option(SessionMetadata),
    expires_at: Timestamp,
    refreshed_at: Timestamp,
  )
}

pub type SessionStore {
  SessionStore(
    /// Insert or replace a session.
    put: fn(SessionRecord) -> Result(Nil, StoreError),
    /// Find a session, whether or not it has expired.
    get: fn(String) -> Result(Option(SessionRecord), StoreError),
    /// Remove a session and its resource subscriptions.
    delete: fn(String) -> Result(Nil, StoreError),
    /// Subscribe a session to updates for a resource URI, or unsubscribe it.
    set_subscription: fn(String, String, Bool) -> Result(Nil, StoreError),
    /// The sessions subscribed to a resource URI.
    subscribers: fn(String) -> Result(List(String), StoreError),
    /// The resource URIs a session is subscribed to.
    subscriptions: fn(String) -> Result(List(String), StoreError),
    /// Remove every session that expired at or before the given time,
    /// returning their ids. Each expired id is returned to exactly one caller.
    delete_expired: fn(Timestamp) -> Result(List(String), StoreError),
  )
}

/// The persisted part of a task. Workers, waiters and resume functions stay
/// with the replica that runs the task.
pub type TaskRecord {
  TaskRecord(
    task: actions.Task,
    /// The owner allowed to read the task, if access is restricted.
    scope: Option(String),
    outcome: Option(Result(actions.TaskResult, jsonrpc.RpcError)),
    /// Input requests that the client has not yet answered.
    inputs: Dict(String, jsonrpc.Value),
    cancellation_status_message: Option(String),
    cancellation_meta: Option(actions.Meta),
    expires_at: Option(Timestamp),
    /// The replica running the task's worker. A task whose owner has stopped
    /// can never finish, so readers fail it.
    owner: Option(String),
    /// Incremented by every write, for optimistic concurrency.
    version: Int,
  )
}

/// Which tasks a listing covers.
pub type TaskScope {
  AnyScope
  Scope(Option(String))
}

pub type TaskStore {
  TaskStore(
    /// Insert a new task.
    insert: fn(TaskRecord) -> Result(Nil, StoreError),
    get: fn(String) -> Result(Option(TaskRecord), StoreError),
    list: fn(TaskScope) -> Result(List(TaskRecord), StoreError),
    /// Replace a task only if the stored version is one less than the given
    /// record's version. Returns False when another writer got there first or
    /// the task no longer exists.
    replace: fn(TaskRecord) -> Result(Bool, StoreError),
    delete: fn(String) -> Result(Nil, StoreError),
    /// Remove every task owned by a scope, returning their ids.
    delete_scope: fn(Option(String)) -> Result(List(String), StoreError),
    /// Remove every task that expired at or before the given time, returning
    /// their ids. Each expired id is returned to exactly one caller.
    delete_expired: fn(Timestamp) -> Result(List(String), StoreError),
  )
}
