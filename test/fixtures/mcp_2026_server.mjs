// Compatibility fixture backed by the official MCP SDK. Install the versions
// pinned in .github/workflows/tests.yml beside a copy of this file.
import { createServer } from 'node:http';
import { McpServer, acceptedContent, createMcpHandler, inputRequired } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { toNodeHandler } from '@modelcontextprotocol/node';
import { z } from 'zod';

const confirmation = z.object({ confirm: z.boolean() });
let handler;

function factory() {
  const server = new McpServer(
    { name: 'official-sdk-2026-fixture', version: '1.0.0' },
    { capabilities: { tools: { listChanged: true }, elicitation: {} } },
  );
  server.registerTool('echo', {
    inputSchema: z.object({ message: z.string().meta({ 'x-mcp-header': 'Message' }) }),
  }, async ({ message }) => ({
    content: [{ type: 'text', text: message }],
    structuredContent: message,
  }));
  server.registerTool('confirm', {
    inputSchema: z.object({ message: z.string() }),
  }, async ({ message }, ctx) => {
    const answer = acceptedContent(ctx.mcpReq.inputResponses, 'confirm', confirmation);
    if (answer?.confirm !== true) {
      return inputRequired({
        inputRequests: {
          confirm: inputRequired.elicit({
            message: 'Confirm the message?',
            requestedSchema: confirmation,
          }),
        },
        requestState: 'opaque fixture state',
      });
    }
    return { content: [{ type: 'text', text: message }] };
  });
  server.registerTool('change_notification', {
    inputSchema: z.object({}),
  }, async () => {
    if (handler) handler.notify.toolsChanged();
    else server.sendToolListChanged();
    return { content: [{ type: 'text', text: 'changed' }] };
  });
  return server;
}

if (process.argv[2] === 'stdio') {
  serveStdio(factory);
} else {
  handler = createMcpHandler(factory, { legacy: 'reject', keepAliveMs: 1000 });
  const serve = toNodeHandler(handler);
  const http = createServer((request, response) => {
    if (request.url === '/health') {
      response.writeHead(200).end('ready');
    } else {
      serve(request, response);
    }
  });
  http.listen(Number(process.env.PORT ?? 3002), '127.0.0.1');
  process.on('SIGTERM', async () => {
    await handler.close();
    http.close();
  });
}
