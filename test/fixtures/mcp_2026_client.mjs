import assert from 'node:assert/strict';
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';

const deadline = setTimeout(() => {
  console.error('Official SDK client compatibility test timed out');
  process.exit(1);
}, 10000);
const client = new Client(
  { name: 'official-sdk-client', version: '1.0.0' },
  { versionNegotiation: { mode: { pin: '2026-07-28' } } },
);
try {
  await client.connect(new StreamableHTTPClientTransport(new URL(process.argv[2])));
  assert.equal(client.getProtocolEra(), 'modern');
  assert.equal(client.getServerVersion()?.name, 'gleam-mcp-test-server');
  const tools = await client.listTools();
  assert.ok(tools.tools.some(tool => tool.name === 'echo'));
  const echo = await client.callTool({ name: 'echo', arguments: { message: 'official July SDK' } });
  assert.equal(echo.content[0].text, 'Echo: official July SDK');
  const resources = await client.listResources();
  assert.ok(resources.resources.some(resource => resource.uri === 'demo://resource/static'));
  const read = await client.readResource({ uri: 'demo://resource/static' });
  assert.equal(read.contents[0].text, 'Static resource contents');
  const prompt = await client.getPrompt({ name: 'simple-prompt' });
  assert.ok(prompt.messages.length > 0);
  await client.close();
} finally {
  clearTimeout(deadline);
}
