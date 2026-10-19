import { serve } from '@hono/node-server';
import { createApp } from './app';
import { loadConfig } from './config';
import { openDb } from './db/client';
import { EventBus } from './events';
import { startSyncLoop } from './mail/scheduler';
import { MailService } from './mail/service';

const config = loadConfig();
const db = openDb(config.dbPath);
const events = new EventBus();
const mail = new MailService(
  db,
  (box) => {
    throw new Error(`no client for provider ${box.provider} yet`);
  },
  events,
);
const onArrived = (ids: string[]) => {
  if (ids.length) console.log(`${ids.length} new message(s)`);
};

const app = createApp({
  version: process.env.npm_package_version ?? 'dev',
  db,
  mail,
  events,
  onArrived,
});

startSyncLoop(mail, onArrived);

serve(
  { fetch: app.fetch, port: config.port, hostname: config.host },
  (info) => {
    console.log(
      `burrow server listening on http://${info.address}:${info.port}`,
    );
  },
);
