import { serve } from '@hono/node-server';
import { createApp } from './app';
import { loadConfig } from './config';
import { openDb } from './db/client';

const config = loadConfig();
const db = openDb(config.dbPath);
const app = createApp({
  version: process.env.npm_package_version ?? 'dev',
  db,
});

serve(
  { fetch: app.fetch, port: config.port, hostname: config.host },
  (info) => {
    console.log(
      `burrow server listening on http://${info.address}:${info.port}`,
    );
  },
);
