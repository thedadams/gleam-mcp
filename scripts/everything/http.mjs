// The Bash parity runner supplies its pinned official SDK checkout.
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { gunzipSync } from 'node:zlib';
import assert from 'node:assert/strict';

const [repo, reference, destination, timeoutArg] = process.argv.slice(2);
if (!repo || !reference || !destination) throw new Error('Use scripts/run-everything-parity.sh');
const timeout = Number(timeoutArg || 20_000);
if (!Number.isSafeInteger(timeout) || timeout <= 0) throw new Error('Invalid timeout');
if (process.platform === 'win32') throw new Error('HTTP integration requires POSIX process-group cleanup');
mkdirSync(destination, { recursive: true });
const sdk = join(reference, 'node_modules/@modelcontextprotocol/sdk');
const load = (name) => import(pathToFileURL(join(sdk, 'dist/esm', name)).href);
const [{ Client }, { StreamableHTTPClientTransport }, { SSEClientTransport }, types] = await Promise.all([
  load('client/index.js'), load('client/streamableHttp.js'), load('client/sse.js'), load('types.js'),
]);
const report = {
  referenceSha: '5abed86c5317b833dd59907492d56c65981642aa',
  sdkVersion: JSON.parse(readFileSync(join(sdk, 'package.json'))).version,
  scope: 'Gleam Everything HTTP integration using the official legacy SDK client; modern wire checks use raw HTTP.',
  protocols: ['2025-11-25', '2026-07-28'], transports: ['streamableHttp', 'sse'],
  checks: [], setupErrors: [],
};
const children = new Set();
const sessions = new Set();
const streams = new Set();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const options = { timeout };
const legacy = '2025-11-25';
const modern = '2026-07-28';
const capabilities = {
  roots: { listChanged: true }, sampling: {}, elicitation: { form: {}, url: {} },
  tasks: { list: {}, cancel: {}, requests: { sampling: { createMessage: {} }, elicitation: { create: {} } } },
};
const toolNames = [
  'echo', 'get-annotated-message', 'get-env', 'get-resource-links', 'get-resource-reference', 'get-roots-list',
  'get-structured-content', 'get-sum', 'get-tiny-image', 'gzip-file-as-resource', 'simulate-research-query',
  'toggle-simulated-logging', 'toggle-subscriber-updates', 'trigger-elicitation-request',
  'trigger-elicitation-request-async', 'trigger-long-running-operation', 'trigger-sampling-request',
  'trigger-sampling-request-async', 'trigger-url-elicitation',
].sort();
let nextId = 0;
let interrupted = false;

async function bounded(promise, label, duration = timeout) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} exceeded ${duration}ms`)), duration);
    })]);
  } finally { clearTimeout(timer); }
}
async function check(name, action) {
  try {
    const details = await bounded(action(), name);
    report.checks.push({ name, passed: true, ...(details ? { details } : {}) });
    console.log(`PASS ${name}`);
    return true;
  } catch (error) {
    report.checks.push({ name, passed: false, error: { message: error.message, code: error.code ?? null } });
    console.log(`FAIL ${name}: ${error.message}`);
    return false;
  }
}
async function waitFor(predicate, label, duration = timeout) {
  const deadline = Date.now() + duration;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await sleep(20);
  }
  throw new Error(`Timed out waiting for ${label}`);
}
async function freePort() {
  const socket = createServer();
  await new Promise((resolve, reject) => { socket.once('error', reject); socket.listen(0, '127.0.0.1', resolve); });
  const port = socket.address().port;
  await new Promise((resolve, reject) => socket.close((error) => error ? reject(error) : resolve()));
  return port;
}
async function launch(mode) {
  const port = await freePort();
  const child = spawn('gleam', ['run', '-m', 'gleam_mcp/examples/everything/main', '--', mode, String(port)], {
    cwd: repo, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +A 2', GZIP_ALLOWED_DOMAINS: '127.0.0.1' },
  });
  children.add(child);
  child.stdout.on('data', (chunk) => appendFileSync(join(destination, `http-${mode}.stdout.log`), chunk));
  child.stderr.on('data', (chunk) => appendFileSync(join(destination, `http-${mode}.stderr.log`), chunk));
  let launchError;
  child.once('error', (error) => { launchError = error; });
  const base = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (launchError) throw launchError;
    if (child.exitCode !== null) throw new Error(`${mode} exited during startup (${child.exitCode})`);
    try {
      const response = await fetch(`${base}/health-probe`, { method: 'OPTIONS', signal: AbortSignal.timeout(250) });
      await response.body?.cancel();
      if (response.status === 204) return { child, base };
    } catch { /* The listener is not bound yet. */ }
    await sleep(50);
  }
  throw new Error(`${mode} did not start within ${timeout}ms`);
}
function signalGroup(child, signal) {
  if (!child.pid) return;
  try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
}
async function stopChild(child) {
  signalGroup(child, 'SIGTERM');
  if (child.exitCode === null && child.signalCode === null) {
    await bounded(new Promise((resolve) => child.once('exit', resolve)), 'server shutdown', 2000).catch(() => {});
  }
  // Descendants may survive their Gleam parent; always kill the isolated group.
  signalGroup(child, 'SIGKILL');
  children.delete(child);
}
async function cleanup() {
  await Promise.allSettled([...streams].map((stream) => stream.close()));
  await Promise.allSettled([...sessions].map((session) => session.close()));
  await Promise.allSettled([...children].map(stopChild));
}
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => {
  interrupted = true;
  await cleanup();
  writeReport();
  process.exit(signal === 'SIGINT' ? 130 : 143);
});

async function openClient(url, mode) {
  const requests = [], postedSessionIds = [], taskRequests = [];
  let roots = [{ uri: 'file:///http/parity', name: 'HTTP parity' }];
  let taskId = 0;
  const tasks = new Map();
  const client = new Client({ name: 'everything-http-client', version: '1.0.0' }, { capabilities });
  const createTask = (params, result) => {
    const task = { taskId: `http-client-task-${++taskId}`, status: 'working', createdAt: new Date().toISOString(), lastUpdatedAt: new Date().toISOString(), ttl: params.task.ttl ?? null, pollInterval: 1 };
    tasks.set(task.taskId, { task, result });
    return { task };
  };
  client.setRequestHandler(types.ListRootsRequestSchema, async () => { requests.push({ method: 'roots/list' }); return { roots }; });
  client.setRequestHandler(types.CreateMessageRequestSchema, async ({ params }) => {
    requests.push({ method: 'sampling/createMessage', params });
    const result = { role: 'assistant', content: { type: 'text', text: 'HTTP sampling answer' }, model: 'http-test-model', stopReason: 'endTurn' };
    return params.task ? createTask(params, result) : result;
  });
  client.setRequestHandler(types.ElicitRequestSchema, async ({ params }) => {
    requests.push({ method: 'elicitation/create', params });
    const content = Object.fromEntries(Object.entries(params.requestedSchema?.properties ?? {}).map(([name, schema]) => [name,
      schema.default ?? schema.const ?? schema.oneOf?.[0]?.const ?? schema.enum?.[0]
      ?? (schema.type === 'boolean' ? true : schema.type === 'integer' || schema.type === 'number' ? 42 : schema.type === 'array' ? [] : 'HTTP User'),
    ]));
    const result = params.mode === 'url' ? { action: 'accept' } : { action: 'accept', content };
    return params.task ? createTask(params, result) : result;
  });
  client.setRequestHandler(types.GetTaskRequestSchema, async ({ params }) => {
    taskRequests.push({ method: 'tasks/get', taskId: params.taskId });
    const entry = tasks.get(params.taskId);
    assert(entry, `Unknown client task ${params.taskId}`);
    entry.task = { ...entry.task, status: 'completed' };
    return entry.task;
  });
  client.setRequestHandler(types.GetTaskPayloadRequestSchema, async ({ params }) => {
    taskRequests.push({ method: 'tasks/result', taskId: params.taskId });
    assert(tasks.has(params.taskId), `Unknown client task ${params.taskId}`);
    return tasks.get(params.taskId).result;
  });
  const instrumentedFetch = async (url, init) => {
    if (init?.method === 'POST' && mode === 'sse') postedSessionIds.push(new URL(url).searchParams.get('sessionId'));
    return fetch(url, init);
  };
  const transport = mode === 'sse'
    ? new SSEClientTransport(new URL(url), { fetch: instrumentedFetch })
    : new StreamableHTTPClientTransport(new URL(url), { fetch: instrumentedFetch });
  const session = {
    client, transport, requests, postedSessionIds, taskRequests,
    setRoots(value) { roots = value; },
    call(name, args = {}, extra = {}) { return client.request({ method: 'tools/call', params: { name, arguments: args, ...extra } }, types.ResultSchema, options); },
    async close() { await bounded(client.close(), 'client close', 2000).catch(() => {}); sessions.delete(session); },
  };
  sessions.add(session);
  try { await client.connect(transport, options); await sleep(450); return session; }
  catch (error) { await session.close(); throw error; }
}
function successful(result) { assert.notEqual(result.isError, true, result.content?.map((item) => item.text).join('\n') || 'Tool returned isError'); return result; }
function text(result) { return successful(result).content.filter((item) => item.type === 'text').map((item) => item.text).join('\n'); }

async function cors(base, path) {
  const response = await fetch(`${base}${path}`, { method: 'OPTIONS', headers: { Origin: 'https://inspector.example', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type,mcp-session-id,mcp-protocol-version' }, signal: AbortSignal.timeout(timeout) });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('access-control-allow-origin'), '*');
  assert.match(response.headers.get('access-control-allow-methods') || '', /POST/);
  assert.match(response.headers.get('access-control-allow-headers') || '', /mcp-session-id/);
  await response.body?.cancel();
}
async function catalog(session) {
  const result = await session.client.listTools({}, options);
  assert.deepEqual(result.tools.map((tool) => tool.name).sort(), toolNames);
  return { tools: result.tools.length };
}
async function reverseRequests(session, prefix) {
  await check(`${prefix}:reverse-sampling`, async () => {
    const before = session.requests.length;
    assert.match(text(await session.call('trigger-sampling-request', { prompt: 'HTTP prompt', maxTokens: 17 })), /HTTP sampling answer/);
    const request = session.requests.slice(before).find((item) => item.method === 'sampling/createMessage');
    assert(request); assert.equal(request.params.maxTokens, 17);
    assert.equal(request.params.messages[0].content.text, 'Resource trigger-sampling-request context: HTTP prompt');
  });
  await check(`${prefix}:reverse-form-and-url-elicitation`, async () => {
    assert.match(text(await session.call('trigger-elicitation-request')), /User inputs:/);
    assert(session.requests.some((item) => Object.keys(item.params?.requestedSchema?.properties || {}).length === 13));
    assert.match(text(await session.call('trigger-url-elicitation', { url: 'https://example.test/http', elicitationId: 'http-url' })), /http-url/);
    assert(session.requests.some((item) => item.params?.mode === 'url' && item.params.url === 'https://example.test/http'));
  });
  await check(`${prefix}:roots-initial-and-list-changed`, async () => {
    assert.match(text(await session.call('get-roots-list')), /file:\/\/\/http\/parity/);
    const before = session.requests.filter((item) => item.method === 'roots/list').length;
    session.setRoots([{ uri: 'file:///http/updated', name: 'Updated HTTP root' }]);
    await session.client.notification({ method: 'notifications/roots/list_changed' });
    await waitFor(() => session.requests.filter((item) => item.method === 'roots/list').length > before, 'roots refresh');
    assert.match(text(await session.call('get-roots-list')), /file:\/\/\/http\/updated/);
  });
  await check(`${prefix}:bidirectional-client-tasks`, async () => {
    assert.match(text(await session.call('trigger-sampling-request-async', { prompt: 'Task prompt' })), /\[COMPLETED\]/);
    assert.match(text(await session.call('trigger-elicitation-request-async')), /\[COMPLETED\]/);
    assert(session.requests.some((item) => item.method === 'sampling/createMessage' && item.params.task));
    assert(session.requests.some((item) => item.method === 'elicitation/create' && item.params.task));
    assert(session.taskRequests.filter((item) => item.method === 'tasks/get').length >= 2);
    assert(session.taskRequests.filter((item) => item.method === 'tasks/result').length >= 2);
  });
}

// Minimal SSE parser for raw wire assertions. It records whether each frame
// actually contains an id field, without inheriting EventSource's last ID.
async function openStream(url, headers, init = {}) {
  const controller = new AbortController();
  const response = await bounded(fetch(url, { ...init, headers, signal: controller.signal }), 'SSE headers');
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type') || '', /^text\/event-stream\b/);
  const stream = streamResponse(response, controller);
  return stream;
}
function streamResponse(response, controller) {
  const events = [];
  const reader = response.body.getReader();
  let closing = false, ended = false, failure;
  const decoder = new TextDecoder();
  const parse = (frame) => {
    const event = { id: null, event: 'message', data: '' };
    const rows = [];
    for (const line of frame.split('\n')) {
      if (line.startsWith(':')) continue;
      const colon = line.indexOf(':');
      const name = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? '' : line.slice(colon + 1);
      if (value.startsWith(' ')) value = value.slice(1);
      if (name === 'id') event.id = value;
      if (name === 'event') event.event = value;
      if (name === 'data') rows.push(value);
    }
    if (!rows.length) return;
    event.data = rows.join('\n');
    try { event.message = JSON.parse(event.data); } catch { /* endpoint events are plain text. */ }
    events.push(event);
  };
  const pump = (async () => {
    let buffer = '';
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        buffer += decoder.decode(chunk.value, { stream: true }).replace(/\r\n/g, '\n');
        let end;
        while ((end = buffer.indexOf('\n\n')) >= 0) { parse(buffer.slice(0, end)); buffer = buffer.slice(end + 2); }
      }
    } catch (error) { if (!closing) failure = error; }
    finally { ended = true; }
  })();
  const stream = {
    events, response,
    async until(predicate, label) {
      return waitFor(() => {
        const value = predicate(events);
        if (value) return value;
        if (failure) throw failure;
        if (ended) throw new Error(`${label}: SSE ended before the expected event`);
        return false;
      }, label);
    },
    async waitEnded(label = 'SSE completion') {
      await bounded(pump, label);
      if (failure) throw failure;
    },
    async close() { closing = true; controller.abort(); await reader.cancel().catch(() => {}); await bounded(pump, 'SSE close', 2000).catch(() => {}); streams.delete(stream); },
  };
  streams.add(stream);
  return stream;
}
function rawHeaders(id, version = legacy) {
  return { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', 'MCP-Protocol-Version': version, ...(id ? { 'MCP-Session-Id': id } : {}) };
}
async function rawPost(url, id, message, version = legacy, accept = 'application/json') {
  const controller = new AbortController();
  const headers = { ...rawHeaders(id, version), Accept: accept };
  if (version === modern) {
    headers['Mcp-Method'] = message.method;
    if (message.params?.name) headers['Mcp-Name'] = message.params.name;
  }
  const response = await bounded(fetch(url, { method: 'POST', headers, body: JSON.stringify(message), signal: controller.signal }), 'HTTP response headers');
  const sessionId = response.headers.get('mcp-session-id');
  if (response.status === 202) { await response.body?.cancel(); return { response, sessionId, messages: [], events: [] }; }
  if (/^text\/event-stream\b/.test(response.headers.get('content-type') || '')) {
    const stream = streamResponse(response, controller);
    try {
      const event = await stream.until((events) => events.find((event) => event.message?.id === message.id && ('result' in event.message || 'error' in event.message)), 'POST JSON-RPC result');
      return { response, sessionId, value: event.message, messages: stream.events.map((event) => event.message), events: [...stream.events] };
    } finally { await stream.close(); }
  }
  return { response, sessionId, value: await bounded(response.json(), 'JSON response'), events: [] };
}
async function rawInitialize(url) {
  const initialized = await rawPost(url, null, { jsonrpc: '2.0', id: ++nextId, method: 'initialize', params: { protocolVersion: legacy, capabilities: {}, clientInfo: { name: 'raw-http-parity', version: '1.0.0' } } });
  assert.equal(initialized.response.status, 200); assert(initialized.sessionId); assert(initialized.value.result);
  const id = initialized.sessionId;
  assert.equal((await rawPost(url, id, { jsonrpc: '2.0', method: 'notifications/initialized' })).response.status, 202);
  return id;
}
const rawCall = (url, id, name, args = {}) => rawPost(url, id, { jsonrpc: '2.0', id: ++nextId, method: 'tools/call', params: { name, arguments: args } });
async function deleteRaw(url, id) {
  const response = await fetch(url, { method: 'DELETE', headers: rawHeaders(id), signal: AbortSignal.timeout(timeout) });
  assert.equal(response.status, 200); await response.body?.cancel();
}
async function replayWhileDisconnected(url) {
  const id = await rawInitialize(url);
  let first, replay;
  const uri = 'demo://resource/dynamic/text/7';
  try {
    const subscribed = await rawPost(url, id, { jsonrpc: '2.0', id: ++nextId, method: 'resources/subscribe', params: { uri } });
    assert(subscribed.value.result);
    first = await openStream(url, { ...rawHeaders(id), Accept: 'text/event-stream' });
    successful((await rawCall(url, id, 'toggle-subscriber-updates')).value.result);
    const initial = await first.until((events) => events.find((event) => event.message?.method === 'notifications/resources/updated'), 'initial resource update');
    assert(initial.id, 'Legacy SSE notification needs an event ID');
    assert.equal(initial.message.params.uri, uri);
    await first.close();
    // The regular five-second simulation emits an update without any listener.
    await sleep(5600);
    replay = await openStream(url, { ...rawHeaders(id), Accept: 'text/event-stream', 'Last-Event-ID': initial.id });
    const missed = await replay.until((events) => events.find((event) => event.message?.method === 'notifications/resources/updated'), 'disconnected update replay');
    assert(missed.id); assert.notEqual(missed.id, initial.id); assert.equal(missed.message.params.uri, uri);
    assert(replay.events.every((event) => event.id !== initial.id), 'Replay must exclude the Last-Event-ID itself');
    await rawCall(url, id, 'toggle-subscriber-updates');
    return { replayedWhileDisconnected: true, notificationsHaveEventIds: true };
  } finally { await first?.close(); await replay?.close(); await deleteRaw(url, id); }
}
async function resumePendingPost(url) {
  const sessionId = await rawInitialize(url);
  const requestId = ++nextId;
  const progressToken = `resumed-post-${requestId}`;
  let original, unrelated, resumed;
  const progress = (event) => event.message?.method === 'notifications/progress'
    && event.message.params?.progressToken === progressToken;
  const final = (event) => event.message?.id === requestId
    && ('result' in event.message || 'error' in event.message);
  try {
    original = await openStream(url, rawHeaders(sessionId), {
      method: 'POST',
      body: JSON.stringify({
        jsonrpc: '2.0', id: requestId, method: 'tools/call',
        params: {
          name: 'trigger-long-running-operation', arguments: { duration: 1.2, steps: 3 },
          _meta: { progressToken },
        },
      }),
    });
    const priming = await original.until((events) => events.find((event) => event.id && event.data === ''), 'POST priming event');
    // Keep one progress frame in the original stream's replay history, while
    // leaving two steps pending. Resumption still uses the priming cursor.
    const firstProgress = await original.until((events) => events.find(progress), 'first POST progress');
    assert(firstProgress.id, 'Progress frame must carry a replay event ID');
    assert.equal(firstProgress.message.params.progress, 1);
    assert(!original.events.some(final), 'Tool completed before the POST was interrupted');
    await original.close();

    unrelated = await openStream(url, { ...rawHeaders(sessionId), Accept: 'text/event-stream' });
    resumed = await openStream(url, {
      ...rawHeaders(sessionId), Accept: 'text/event-stream', 'Last-Event-ID': priming.id,
    });
    const replayed = await resumed.until((events) => events.find((event) => event.id === firstProgress.id), 'POST progress replay');
    assert(progress(replayed), 'Cursor replayed an unrelated progress frame');
    const completed = await resumed.until((events) => events.find(final), 'resumed POST result');
    assert(completed.id, 'Final response must carry a replay event ID');
    assert(completed.message.result, `Resumed tool returned an error: ${JSON.stringify(completed.message.error)}`);
    assert.match(text(completed.message.result), /Duration: 1\.2 seconds, Steps: 3\./);
    await resumed.waitEnded('resumed POST closes after its final response');
    assert.deepEqual(resumed.events.filter(progress).map((event) => event.message.params.progress), [1, 2, 3]);
    assert.equal(resumed.events.filter(final).length, 1, 'Final response was duplicated');
    assert(resumed.events.every((event) => event.id !== priming.id), 'Replay included its cursor');
    assert(!unrelated.events.some(final), 'Unrelated GET received the POST response');
    assert(!unrelated.events.some(progress), 'Unrelated GET received progress from the resumed POST stream');
    return { resumedBeforeCompletion: true, progressReplayIsolated: true, finalOnResumedStream: true, closedAfterFinal: true, reconnects: 1 };
  } finally {
    await original?.close(); await unrelated?.close(); await resumed?.close();
    await deleteRaw(url, sessionId);
  }
}
async function modernWire(url) {
  const meta = {
    'io.modelcontextprotocol/protocolVersion': modern,
    'io.modelcontextprotocol/clientCapabilities': capabilities,
    'io.modelcontextprotocol/clientInfo': { name: 'modern-http-parity', version: '1.0.0' },
  };
  const discovered = await rawPost(url, null, { jsonrpc: '2.0', id: ++nextId, method: 'server/discover', params: { _meta: meta } }, modern);
  assert.equal(discovered.response.status, 200); assert.equal(discovered.sessionId, null);
  assert.equal(discovered.value.result.resultType, 'complete');
  assert(discovered.value.result.supportedVersions.includes(modern));
  const result = await rawPost(url, null, { jsonrpc: '2.0', id: ++nextId, method: 'tools/call', params: { name: 'trigger-long-running-operation', arguments: { duration: 0.1, steps: 3 }, _meta: { ...meta, progressToken: 'modern-progress' } } }, modern, 'application/json, text/event-stream');
  assert.equal(result.response.status, 200); assert.equal(result.sessionId, null);
  assert.equal(result.value.result.resultType, 'complete'); successful(result.value.result);
  assert(result.events.some((event) => event.message?.method === 'notifications/progress'), 'Expected modern progress SSE frames');
  assert(result.events.every((event) => event.id === null), 'Modern SSE must not acquire legacy resumption IDs');
  return { resultType: 'complete', stateless: true, progressFramesWithoutIds: true };
}

async function streamableChecks(base) {
  const url = `${base}/mcp`;
  await check('streamable:CORS-and-OPTIONS', () => cors(base, '/mcp'));
  let alice, bob;
  try {
    alice = await openClient(url, 'streamableHttp');
    await check('streamable:all-capabilities-19-tools', () => catalog(alice));
    await reverseRequests(alice, 'streamable');
    await check('streamable:server-task-lifecycle', async () => {
      const created = await alice.call('simulate-research-query', { topic: 'http research', ambiguous: true }, { task: { ttl: 300000 } });
      assert(created.task?.taskId);
      const initial = await alice.client.experimental.tasks.getTask(created.task.taskId, options); assert.equal(initial.taskId, created.task.taskId);
      const result = await alice.client.experimental.tasks.getTaskResult(created.task.taskId, types.ResultSchema, options);
      assert.match(text(result), /http research/);
      assert.equal((await alice.client.experimental.tasks.getTask(created.task.taskId, options)).status, 'completed');
    });
    bob = await openClient(url, 'streamableHttp');
    await check('streamable:gzip-resources-isolated-by-session', async () => {
      const created = successful(await alice.call('gzip-file-as-resource', { name: 'isolation.gz', data: 'data:,alice' }));
      const uri = created.content[0].uri; assert(uri);
      await assert.rejects(bob.client.readResource({ uri }, options));
      successful(await bob.call('gzip-file-as-resource', { name: 'isolation.gz', data: 'data:,bob' }));
      const a = (await alice.client.readResource({ uri }, options)).contents[0];
      const b = (await bob.client.readResource({ uri }, options)).contents[0];
      assert.equal(gunzipSync(Buffer.from(a.blob, 'base64')).toString(), 'alice');
      assert.equal(gunzipSync(Buffer.from(b.blob, 'base64')).toString(), 'bob');
    });
    await check('streamable:DELETE-cleans-session-and-resources', async () => {
      const previous = alice.transport.sessionId; assert(previous);
      await alice.transport.terminateSession();
      assert.equal(alice.transport.sessionId, undefined);
      const response = await fetch(url, { headers: { ...rawHeaders(previous), Accept: 'text/event-stream' }, signal: AbortSignal.timeout(timeout) });
      assert.equal(response.status, 404); await response.body?.cancel();
      await alice.close();
      assert((await bob.client.readResource({ uri: 'demo://resource/session/isolation.gz' }, options)).contents.length > 0, 'Deleting Alice must preserve Bob');
    });
  } finally {
    await Promise.allSettled([alice?.close(), bob?.transport.terminateSession()]);
    await bob?.close();
  }
  await check('streamable:SSE-id-and-disconnected-Last-Event-ID-replay', () => replayWhileDisconnected(url));
  await check('streamable:interrupted-POST-resumes-before-completion-and-closes', () => resumePendingPost(url));
  await check('streamable:modern-stateless-SSE-has-no-legacy-event-ids', () => modernWire(url));
}
async function deprecatedChecks(base) {
  await check('deprecated-sse:CORS-and-OPTIONS', () => cors(base, '/message'));
  let session, next;
  try {
    session = await openClient(`${base}/sse`, 'sse');
    await check('deprecated-sse:all-capabilities-19-tools', () => catalog(session));
    await reverseRequests(session, 'deprecated-sse');
    let oldId;
    await check('deprecated-sse:persistent-endpoint-session-and-multiple-results', async () => {
      assert.equal(text(await session.call('echo', { message: 'one' })), 'Echo: one');
      assert.equal(text(await session.call('echo', { message: 'two' })), 'Echo: two');
      const ids = new Set(session.postedSessionIds);
      assert.equal(ids.size, 1); assert(!ids.has(null)); oldId = [...ids][0];
      return { oneEndpointSession: true, multipleResults: true };
    });
    await check('deprecated-sse:disconnect-cleans-session-resources', async () => {
      const result = successful(await session.call('gzip-file-as-resource', { name: 'closed.gz', data: 'data:,temporary' }));
      const uri = result.content[0].uri; assert(uri);
      await session.close();
      await sleep(100);
      const response = await fetch(`${base}/message?sessionId=${encodeURIComponent(oldId)}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }), signal: AbortSignal.timeout(timeout) });
      assert.equal(response.status, 404); await response.body?.cancel();
      next = await openClient(`${base}/sse`, 'sse');
      await assert.rejects(next.client.readResource({ uri }, options));
    });
  } finally { await Promise.allSettled([session?.close(), next?.close()]); }
}
function writeReport() {
  const failed = report.checks.filter((entry) => !entry.passed);
  report.summary = { total: report.checks.length, passed: report.checks.length - failed.length, failed: failed.length, incomplete: report.setupErrors.length + Number(interrupted) };
  writeFileSync(join(destination, 'http-summary.json'), JSON.stringify(report, null, 2) + '\n');
  writeFileSync(join(destination, 'http-summary.txt'), `${JSON.stringify(report.summary)}\n${failed.map((entry) => `FAIL ${entry.name}: ${entry.error.message}`).join('\n')}\n${report.setupErrors.map((entry) => `INCOMPLETE ${entry.stage}: ${entry.message}`).join('\n')}\n`);
}
try {
  for (const [mode, exercise] of [['streamableHttp', streamableChecks], ['sse', deprecatedChecks]]) {
    let launched;
    try { launched = await launch(mode); await exercise(launched.base); }
    catch (error) { report.setupErrors.push({ stage: mode, message: error.message }); console.error(`INCOMPLETE ${mode}: ${error.message}`); }
    finally { if (launched) await stopChild(launched.child); }
  }
} finally {
  await cleanup();
  writeReport();
  console.log(JSON.stringify(report.summary));
  process.exitCode = report.summary.incomplete ? 2 : report.summary.failed ? 1 : 0;
}
