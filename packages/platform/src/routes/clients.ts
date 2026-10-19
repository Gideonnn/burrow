import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { clientRelease } from '@burrow/contracts';
import { Hono } from 'hono';
import type { PlatformEnv } from '../env';

// Builds of the native clients (one per module app), published into
// `<data>/clients/<client>/` by the release script. Any key may fetch them:
// they are signed, and the client checks the signature before installing.
export function clientRoutes(dir: string, clients: readonly string[]) {
  const CLIENTS = new Set(clients);
  return new Hono<PlatformEnv>()
    .get('/clients/:client/latest', async (c) => {
      const client = c.req.param('client');
      if (!CLIENTS.has(client)) return c.json({ error: 'unknown client' }, 404);
      const raw = await readFile(
        join(dir, client, 'latest.json'),
        'utf8',
      ).catch(() => undefined);
      if (!raw) return c.json({ error: 'nothing published yet' }, 404);
      return c.json(clientRelease.parse(JSON.parse(raw)));
    })
    .get('/clients/:client/:file{[0-9]+\\.zip}', async (c) => {
      const client = c.req.param('client');
      if (!CLIENTS.has(client)) return c.json({ error: 'unknown client' }, 404);
      const zip = await readFile(join(dir, client, c.req.param('file'))).catch(
        () => undefined,
      );
      if (!zip) return c.json({ error: 'no such build' }, 404);
      return c.body(zip, 200, { 'content-type': 'application/zip' });
    });
}
