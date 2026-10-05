// Run only through run-everything-parity.sh: imports come from its pinned checkout.
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { isDeepStrictEqual } from 'node:util';

const [repo, reference, destination, timeoutArg] = process.argv.slice(2);
if (!repo || !reference || !destination) throw new Error('Use run-everything-parity.sh');
const timeout = Number(timeoutArg || 20_000);
const sdk = join(reference, 'node_modules/@modelcontextprotocol/sdk');
const load = (name) => import(pathToFileURL(join(sdk, 'dist/esm', name)).href);
const [{ Client }, { StdioClientTransport }, types] = await Promise.all([
  load('client/index.js'), load('client/stdio.js'), load('types.js'),
]);
const report = {
  referenceSha: '5abed86c5317b833dd59907492d56c65981642aa',
  referenceVersion: JSON.parse(readFileSync(join(reference, 'src/everything/package.json'))).version,
  sdkVersion: JSON.parse(readFileSync(join(sdk, 'package.json'))).version,
  protocol: '2025-11-25', transport: 'stdio',
  normalization: [
    'Object keys; catalogs keyed by stable name/URI (catalog order is unspecified).',
    'Generated task/elicitation/session IDs and task timestamps only.',
    'Dynamic resource local creation time only; content and MIME types remain compared.',
    'Environment tool: validate string-valued object and explicit fixture variable, redact other values.',
    'Task poll history scheduling is observed but final results and task fields are compared.',
    'Gzip bytes use different OS/library headers: independently gunzip and compare payloads plus MIME/URI/result metadata; retain original headers/bytes in compressionArtifacts.',
  ],
  compatibilityNotes: [
    'Upstream returns raw spaces in generated resource URIs, but its SDK canonicalizes those spaces to %20 on read and cannot roundtrip that link. The spaced-name check compares the raw link and embedded resource output instead.',
  ],
  checks: [], setupErrors: [], compressionArtifacts: [],
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const options = { timeout };
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(
    Object.keys(value).sort().map((key) => [key, canonical(value[key])]),
  );
  return value;
}
function normalize(value, ids = new Map(), key = '') {
  if (Array.isArray(value)) return value.map((entry) => normalize(entry, ids));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .map(([key, entry]) => [key, normalize(entry, ids, key)]));
  if (typeof value !== 'string') return value;
  if (['createdAt', 'lastUpdatedAt'].includes(key)) return '<timestamp>';
  if (['taskId', 'elicitationId'].includes(key)) {
    if (!ids.has(value)) ids.set(value, `<${key}-${ids.size + 1}>`);
    return ids.get(value);
  }
  let text = value.replace(/^(Resource \d+: This is a plaintext resource created at )[^\n]+$/, '$1<local-time>')
    .replace(/(for session )[^\s.,]+/g, '$1<session-id>');
  // Embedded binary dynamic resources contain the same timestamped text.
  if (key === 'blob') {
    const decoded = Buffer.from(text, 'base64').toString('utf8');
    if (/^Resource \d+: This is a base64 blob created at /.test(decoded)) {
      return Buffer.from(decoded.replace(/(created at )[^\n]+/, '$1<local-time>')).toString('base64');
    }
  }
  for (const [id, replacement] of ids) text = text.split(id).join(replacement);
  // Preserve content text while comparing object key order inside its JSON tail.
  // Parse only a complete JSON suffix. This also handles "Raw result: {"
  // while preserving every character of the preceding human-readable text.
  for (let offset = 0; offset < text.length; offset++) {
    if (text[offset] !== '{' && text[offset] !== '[') continue;
    try {
      text = text.slice(0, offset) + JSON.stringify(canonical(JSON.parse(text.slice(offset))), null, 2);
      break;
    } catch { /* Keep searching; no non-JSON text is removed. */ }
  }
  return text;
}
function gzipPayload(value, expected, peer, scenario) {
  if (Array.isArray(value)) return value.map((entry) => gzipPayload(entry, expected, peer, scenario));
  if (!value || typeof value !== 'object') return value;
  if (value.mimeType === 'application/gzip' && typeof value.blob === 'string') {
    const compressed = Buffer.from(value.blob, 'base64');
    assert(compressed[0] === 0x1f && compressed[1] === 0x8b && compressed[2] === 8, 'Output is not an RFC1952 gzip container');
    const decoded = gunzipSync(compressed);
    assert(decoded.equals(expected), 'gzip did not decode to original bytes');
    report.compressionArtifacts.push({ peer, scenario, compressed: value.blob,
      header: { flags: compressed[3], mtime: compressed.readUInt32LE(4), xfl: compressed[8], os: compressed[9] },
      decodedBytes: decoded.length });
    return { ...value, blob: `<gzip decoded: ${decoded.toString('base64')}>` };
  }
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, gzipPayload(entry, expected, peer, scenario)]));
}
function check(name, official, gleam, details) {
  const a = canonical(normalize(official));
  const b = canonical(normalize(gleam));
  const unexpectedError = name !== 'elicitation:url:error' && (a?.error || b?.error);
  const passed = isDeepStrictEqual(a, b) && !unexpectedError;
  const differences = passed ? [] : changedPaths(a, b);
  report.checks.push({ name, passed, official: a, gleam: b, differences, ...(details ? { details } : {}) });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) console.log(`  ${unexpectedError ? 'Unexpected operation error. ' : ''}${differences.slice(0, 12).join(', ')}`);
}
function changedPaths(a, b, path = '$', output = []) {
  if (isDeepStrictEqual(a, b)) return output;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) changedPaths(a[key], b[key], `${path}.${key}`, output);
  } else output.push(path);
  return output;
}
function assert(condition, message) { if (!condition) throw new Error(message); }
function errorValue(error) {
  return { error: { code: error.code ?? null, message: error.message, ...(error.data ? { data: error.data } : {}) } };
}
async function capture(action) { try { return await action(); } catch (error) { return errorValue(error); } }
function catalog(items, key) { return Object.fromEntries(items.map((item) => [item[key], item])); }
const roots = [{ uri: 'file:///parity/project', name: 'Parity project' }];
const capabilities = {
  roots: { listChanged: true }, sampling: {}, elicitation: { form: {}, url: {} },
  tasks: { list: {}, cancel: {}, requests: { sampling: { createMessage: {} }, elicitation: { create: {} } } },
};
const matrix = [
  ['none', {}], ['sampling', { sampling: {} }],
  ['form', { elicitation: { form: {} } }], ['url', { elicitation: { url: {} } }],
  ['roots', { roots: { listChanged: true } }], ['all', capabilities],
];
const environment = Object.fromEntries(['PATH', 'HOME', 'LANG', 'TMPDIR', 'ERL_FLAGS']
  .filter((key) => process.env[key] !== undefined).map((key) => [key, process.env[key]]));
environment.MCP_PARITY_FIXTURE = 'everything-reference-v2';
environment.GZIP_ALLOWED_DOMAINS = '127.0.0.1';
environment.GZIP_MAX_FETCH_SIZE = '1024';
environment.GZIP_MAX_FETCH_TIME_MILLIS = '1000';

async function open(peer, advertised, suffix) {
  const callbackRequests = [];
  const notifications = { resources: [], progress: [], logs: [] };
  let currentRoots = roots;
  let clientTaskIndex = 0;
  const clientTasks = new Map();
  const client = new Client({ name: 'everything-parity-client', version: '1.0.0' }, { capabilities: advertised });
  const createClientTask = (params, result) => {
    const task = {
      taskId: `parity-client-task-${++clientTaskIndex}`, status: 'working',
      createdAt: '2026-01-01T00:00:00.000Z', lastUpdatedAt: '2026-01-01T00:00:00.000Z',
      ttl: params.task.ttl ?? null, pollInterval: 1,
    };
    clientTasks.set(task.taskId, { task, result });
    return { task };
  };
  if (advertised.roots) client.setRequestHandler(types.ListRootsRequestSchema, async () => ({ roots: currentRoots }));
  if (advertised.sampling) client.setRequestHandler(types.CreateMessageRequestSchema, async ({ params }) => {
    callbackRequests.push({ method: 'sampling/createMessage', params });
    const result = { role: 'assistant', content: { type: 'text', text: 'Parity sampling answer' }, model: 'parity-model', stopReason: 'endTurn' };
    return params.task ? createClientTask(params, result) : result;
  });
  if (advertised.elicitation) client.setRequestHandler(types.ElicitRequestSchema, async ({ params }) => {
    callbackRequests.push({ method: 'elicitation/create', params });
    const content = {};
    for (const [name, schema] of Object.entries(params.requestedSchema?.properties ?? {})) {
      content[name] = schema.default ?? schema.const ?? schema.oneOf?.[0]?.const ?? schema.enum?.[0]
        ?? (schema.type === 'boolean' ? true : schema.type === 'number' || schema.type === 'integer' ? 42 : schema.type === 'array' ? [] : 'Parity User');
    }
    const result = params.mode === 'url' ? { action: 'accept' } : { action: 'accept', content };
    return params.task ? createClientTask(params, result) : result;
  });
  if (advertised.tasks) {
    client.setRequestHandler(types.GetTaskRequestSchema, async ({ params }) => {
      const entry = clientTasks.get(params.taskId);
      assert(entry, `Unknown client task ${params.taskId}`);
      entry.task = { ...entry.task, status: 'completed' };
      return entry.task;
    });
    client.setRequestHandler(types.GetTaskPayloadRequestSchema, async ({ params }) => {
      assert(clientTasks.has(params.taskId), `Unknown client task ${params.taskId}`);
      return clientTasks.get(params.taskId).result;
    });
  }
  client.setNotificationHandler(types.ResourceUpdatedNotificationSchema, ({ params }) => notifications.resources.push(params));
  client.setNotificationHandler(types.LoggingMessageNotificationSchema, ({ params }) => notifications.logs.push(params));
  const transport = new StdioClientTransport(peer === 'official' ? {
    command: process.execPath, args: [join(reference, 'src/everything/dist/index.js'), 'stdio'], cwd: reference, env: environment, stderr: 'pipe',
  } : {
    command: 'gleam', args: ['run', '-m', 'gleam_mcp/examples/everything/main', '--', 'stdio'], cwd: repo, env: environment, stderr: 'pipe',
  });
  transport.stderr?.on('data', (chunk) => appendFileSync(join(destination, `${peer}-${suffix}.stderr.log`), chunk));
  try {
    await client.connect(transport, options);
    // Upstream installs conditional tools during initialized and starts roots sync after 350ms.
    await sleep(450);
    return { peer, client, transport, callbackRequests, notifications,
      setRoots(value) { currentRoots = value; },
      async close() { await client.close(); await transport.close(); },
    };
  } catch (error) { await transport.close(); throw error; }
}

async function exercise(session) {
  const { client, notifications, callbackRequests } = session;
  const values = {};
  const call = (name, args = {}, extra = {}) => client.request({ method: 'tools/call', params: { name, arguments: args, ...extra } }, types.ResultSchema, options);
  const record = async (name, action) => { values[name] = await capture(action); };
  values.capabilities = client.getServerCapabilities();
  values.serverInfo = client.getServerVersion();
  values.instructions = client.getInstructions();
  values.prompts = catalog((await client.listPrompts({}, options)).prompts, 'name');
  values.resources = catalog((await client.listResources({}, options)).resources, 'uri');
  values.templates = catalog((await client.listResourceTemplates({}, options)).resourceTemplates, 'uriTemplate');
  for (const [name, args] of [
    ['echo', { message: 'Parity hello' }], ['get-sum', { a: 12, b: 30 }],
    ['get-tiny-image', {}], ['get-resource-links', {}],
    ['get-resource-reference', { resourceType: 'Text', resourceId: 7 }],
    ['get-resource-reference', { resourceType: 'Blob', resourceId: 8 }],
    ...['error', 'success', 'debug'].map((messageType) => ['get-annotated-message', { messageType, includeImage: true }]),
    ...['New York', 'Chicago', 'Los Angeles'].map((location) => ['get-structured-content', { location }]),
  ]) await record(`tool:${name}:${JSON.stringify(args)}`, () => call(name, args));
  await record('tool:get-env', async () => {
    const value = await call('get-env');
    const env = JSON.parse(value.content[0].text);
    assert(Object.values(env).every((item) => typeof item === 'string'), 'get-env must contain string values');
    assert(env.MCP_PARITY_FIXTURE === environment.MCP_PARITY_FIXTURE, 'get-env did not return fixture variable');
    return { content: [{ type: 'text', text: '<environment>' }], fixture: env.MCP_PARITY_FIXTURE };
  });
  for (const [name, args] of [
    ['simple-prompt', {}], ['args-prompt', { city: 'Portland', state: 'Oregon' }],
    ['args-prompt', { city: 'Portland' }], ['completable-prompt', { department: 'Sales', name: 'Eve' }],
    ['resource-prompt', { resourceType: 'Text', resourceId: '7' }],
    ['resource-prompt', { resourceType: 'Blob', resourceId: '8' }],
  ]) await record(`prompt:${name}:${JSON.stringify(args)}`, () => client.getPrompt({ name, arguments: args }, options));
  for (const [name, argument, value, context] of [
    ['completable-prompt', 'department', 'S'], ['completable-prompt', 'name', '', { arguments: { department: 'Engineering' } }],
    ['completable-prompt', 'name', 'a', { arguments: { department: 'Engineering' } }],
    ['resource-prompt', 'resourceType', 'B'], ['resource-prompt', 'resourceId', '1e3'],
  ]) await record(`completion:${name}:${argument}:${value}`, () => client.complete({ ref: { type: 'ref/prompt', name }, argument: { name: argument, value }, ...(context ? { context } : {}) }, options));
  for (const uri of Object.keys(values.resources).concat(['demo://resource/dynamic/text/7', 'demo://resource/dynamic/blob/8'])) {
    await record(`read:${uri}`, () => client.readResource({ uri }, options));
  }
  for (const uri of ['demo://resource/dynamic/text/{resourceId}', 'demo://resource/dynamic/blob/{resourceId}']) {
    await record(`completion:${uri}`, () => client.complete({ ref: { type: 'ref/resource', uri }, argument: { name: 'resourceId', value: '123' } }, options));
  }
  for (const outputType of ['resourceLink', 'resource']) await record(`gzip:${outputType}`, async () => {
    const result = await call('gzip-file-as-resource', { name: 'parity.gz', data: 'data:application/octet-stream;base64,AP9oZWxsbw==', outputType });
    const resource = result.content[0].type === 'resource' ? result.content[0].resource
      : (await client.readResource({ uri: result.content[0].uri }, options)).contents[0];
    return gzipPayload({ result, resource }, Buffer.from([0, 255, ...Buffer.from('hello')]), session.peer, outputType);
  });
  await record('gzip:replacement', async () => {
    const result = await call('gzip-file-as-resource', { name: 'parity.gz', data: 'data:,replacement' });
    const resource = (await client.readResource({ uri: result.content[0].uri }, options)).contents[0];
    return gzipPayload({ result, resource }, Buffer.from('replacement'), session.peer, 'replacement');
  });
  await record('gzip:percent-encoded-binary', async () => {
    const result = await call('gzip-file-as-resource', { name: 'binary.gz', data: 'data:application/octet-stream,%00%ff%80' });
    const resource = (await client.readResource({ uri: result.content[0].uri }, options)).contents[0];
    return gzipPayload({ result, resource }, Buffer.from([0, 255, 128]), session.peer, 'percent-encoded-binary');
  });
  await record('gzip:space-in-name', async () => {
    const result = await call('gzip-file-as-resource', { name: 'space name.gz', data: 'data:,space' });
    assert(result.content[0].uri === 'demo://resource/session/space name.gz', 'Legacy resource name was URI-encoded');
    const embedded = await call('gzip-file-as-resource', { name: 'space name.gz', data: 'data:,space', outputType: 'resource' });
    assert(embedded.content[0].type === 'resource', 'Expected embedded gzip resource');
    assert(embedded.content[0].resource.uri === result.content[0].uri, 'Embedded resource lost the raw spaced name');
    return gzipPayload({ result, embedded }, Buffer.from('space'), session.peer, 'space-in-name');
  });
  await record('sampling', () => call('trigger-sampling-request', { prompt: 'Parity sampling', maxTokens: 17 }));
  await record('elicitation:form', () => call('trigger-elicitation-request'));
  const urlArguments = { url: 'https://example.test/parity', message: 'Parity URL flow', elicitationId: 'parity-url' };
  await record('elicitation:url', () => call('trigger-url-elicitation', urlArguments));
  await record('elicitation:url:error', () => call('trigger-url-elicitation', { ...urlArguments, errorPath: true }));
  await record('elicitation:url:retry', () => call('trigger-url-elicitation', { ...urlArguments, errorPath: true }));
  await record('sampling:client-task', () => call('trigger-sampling-request-async', { prompt: 'Parity async sampling', maxTokens: 17 }));
  await record('elicitation:client-task', () => call('trigger-elicitation-request-async'));
  await record('roots:initial', () => call('get-roots-list'));
  session.setRoots([{ uri: 'file:///parity/updated', name: 'Updated project' }]);
  await client.notification({ method: 'notifications/roots/list_changed' });
  await sleep(100);
  await record('roots:updated', () => call('get-roots-list'));
  await record('progress', async () => {
    const progress = [];
    const result = await client.request({ method: 'tools/call', params: { name: 'trigger-long-running-operation', arguments: { duration: 0.03, steps: 3 } } }, types.ResultSchema, { ...options, onprogress: (params) => progress.push(params) });
    return { result, progress };
  });
  const resourceUri = 'demo://resource/dynamic/text/7';
  await client.subscribeResource({ uri: resourceUri }, options);
  await record('subscriptions:start', () => call('toggle-subscriber-updates'));
  await sleep(100);
  values['subscriptions:notifications'] = notifications.resources;
  await record('subscriptions:stop', () => call('toggle-subscriber-updates'));
  await client.unsubscribeResource({ uri: resourceUri }, options);
  await client.setLoggingLevel('debug', options);
  const logCount = notifications.logs.length;
  await record('logging:start', () => call('toggle-simulated-logging'));
  await sleep(100);
  await record('logging:notifications', async () => {
    const simulated = notifications.logs.slice(logCount);
    assert(simulated.length > 0, 'No immediate simulated log notification');
    const messages = {
      debug: 'Debug-level message', info: 'Info-level message', notice: 'Notice-level message',
      warning: 'Warning-level message', error: 'Error-level message', critical: 'Critical-level message',
      alert: 'Alert level-message', emergency: 'Emergency-level message',
    };
    assert(simulated.every((item) => item.data.replace(/ - SessionId .+$/, '') === messages[item.level]), 'Simulated logging level/text mismatch');
    // Selection is random by design; validate its contract rather than compare a random draw.
    return { received: true, validLevelAndMessage: true, loggerFields: simulated.map((item) => item.logger ?? null) };
  });
  await record('logging:stop', () => call('toggle-simulated-logging'));
  for (const ambiguous of [false, true]) await record(`research:${ambiguous}`, async () => {
    const created = await call('simulate-research-query', { topic: 'python', ambiguous }, { task: { ttl: 300000 } });
    assert(created.task?.taskId, 'Research tool did not create a task');
    const initial = await client.experimental.tasks.getTask(created.task.taskId, options);
    const result = await client.experimental.tasks.getTaskResult(created.task.taskId, types.ResultSchema, options);
    const final = await client.experimental.tasks.getTask(created.task.taskId, options);
    assert(final.status === 'completed', `Research finished with ${final.status}`);
    return { created, initial, final, result };
  });
  await record('research:cancel', async () => {
    const created = await call('simulate-research-query', { topic: 'cancelled parity', ambiguous: false }, { task: { ttl: 300000 } });
    assert(created.task?.taskId, 'Research tool did not create a cancellable task');
    return client.experimental.tasks.cancelTask(created.task.taskId, options);
  });
  values.callbackRequests = callbackRequests;
  return values;
}

try {
  for (const [name, advertised] of matrix) {
    let a, b;
    try {
      a = await open('official', advertised, name);
      b = await open('gleam', advertised, name);
      const left = catalog((await a.client.listTools({}, options)).tools, 'name');
      const right = catalog((await b.client.listTools({}, options)).tools, 'name');
      check(`tools:${name}`, left, right);
      check(`capabilities:${name}`, a.client.getServerCapabilities(), b.client.getServerCapabilities());
      if (name === 'all') {
        const official = await exercise(a);
        const gleam = await exercise(b);
        for (const key of new Set([...Object.keys(official), ...Object.keys(gleam)])) check(key, official[key], gleam[key]);
      }
    } catch (error) {
      report.setupErrors.push({ stage: name, ...errorValue(error) });
      console.error(`INCOMPLETE ${name}: ${error.message}`);
    } finally {
      await Promise.allSettled([a?.close(), b?.close()]);
    }
  }
} finally {
  const failed = report.checks.filter((entry) => !entry.passed);
  report.summary = { total: report.checks.length, passed: report.checks.length - failed.length, failed: failed.length, incomplete: report.setupErrors.length };
  writeFileSync(join(destination, 'stdio-summary.json'), JSON.stringify(report, null, 2) + '\n');
  writeFileSync(join(destination, 'stdio-summary.txt'), `${JSON.stringify(report.summary)}\n${failed.map((entry) => `FAIL ${entry.name}`).join('\n')}\n${report.setupErrors.map((entry) => `INCOMPLETE ${entry.stage}: ${entry.error.message}`).join('\n')}\n`);
  console.log(JSON.stringify(report.summary));
  process.exitCode = report.setupErrors.length ? 2 : failed.length ? 1 : 0;
}
