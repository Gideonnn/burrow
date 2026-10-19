import { serve } from '@hono/node-server';
import { createApp } from './app';
import { loadConfig } from './config';

const config = loadConfig();
const app = createApp({ version: process.env.npm_package_version ?? 'dev' });

serve(
  { fetch: app.fetch, port: config.port, hostname: config.host },
  (info) => {
    console.log(
      `burrow server listening on http://${info.address}:${info.port}`,
    );
  },
);
