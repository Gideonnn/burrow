import { StreamableHTTPTransport } from '@hono/mcp';
import { Hono } from 'hono';
import type { AppEnv } from '../env';
import { createMcpServer } from '../mcp/server';

// Stateless streamable HTTP: each request gets its own server and transport,
// bound to the key that made it. Mounted behind the key middleware.
export function mcpRoutes(version: string) {
  return new Hono<AppEnv>().all('/mcp', async (c) => {
    const server = createMcpServer({
      db: c.var.db,
      mail: c.var.mail,
      access: c.var.access,
      version,
    });
    const transport = new StreamableHTTPTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    await server.connect(transport);
    return transport.handleRequest(c);
  });
}
