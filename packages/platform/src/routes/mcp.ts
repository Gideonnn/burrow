import { StreamableHTTPTransport } from '@hono/mcp';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Hono } from 'hono';
import type { PlatformEnv } from '../env';
import { registerPlatformTools } from '../mcp';

// Stateless streamable HTTP: each request gets its own server and transport,
// bound to the key that made it. Every module adds its tools; tools that need
// a right the key lacks are not registered, so the agent never sees them.
export function mcpRoutes(version: string) {
  return new Hono<PlatformEnv>().all('/mcp', async (c) => {
    const server = new McpServer({ name: 'burrow', version });
    registerPlatformTools(server, c.var.platform, c.var.access);
    for (const module of c.var.platform.modules) {
      module.mcp?.(server, c.var.access);
    }
    const transport = new StreamableHTTPTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    await server.connect(transport);
    return transport.handleRequest(c);
  });
}
