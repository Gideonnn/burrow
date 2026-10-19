import { serve } from '@hono/node-server';
import { createApp } from './app';
import { loadConfig } from './config';
import { SecretBox } from './crypto/secretBox';
import { openDb } from './db/client';
import { EventBus } from './events';
import { Accounts } from './mail/accounts';
import { startSyncLoop } from './mail/scheduler';
import { MailService } from './mail/service';

const config = loadConfig();
if (!config.secretKey) {
  console.error(
    'BURROW_SECRET_KEY is not set. Generate one with `pnpm --filter @burrow/server cli generate-secret`.',
  );
  process.exit(1);
}

const db = openDb(config.dbPath);
const events = new EventBus();
const accounts = new Accounts({
  db,
  box: new SecretBox(config.secretKey),
  publicUrl: config.publicUrl,
  apps: { gmail: config.google, microsoft: config.microsoft },
});
const mail = new MailService(db, accounts.clientFor, events);
const onArrived = (ids: string[]) => {
  if (ids.length) console.log(`${ids.length} new message(s)`);
};

const app = createApp({
  version: process.env.npm_package_version ?? 'dev',
  db,
  mail,
  events,
  accounts,
  onArrived,
});

startSyncLoop(mail, onArrived);

serve(
  { fetch: app.fetch, port: config.port, hostname: config.host },
  (info) => {
    console.log(
      `burrow server listening on http://${info.address}:${info.port}`,
    );
    console.log(`public URL for OAuth: ${config.publicUrl}`);
  },
);
