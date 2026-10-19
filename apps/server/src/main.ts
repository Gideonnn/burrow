import { serve } from '@hono/node-server';
import {
  ClaudeCliRunner,
  CodexCliRunner,
  FallbackRunner,
} from './agents/runner';
import { createApp } from './app';
import { loadCatalog } from './catalog/loadCatalog';
import { loadConfig } from './config';
import { SecretBox } from './crypto/secretBox';
import { openDb } from './db/client';
import { EventBus } from './events';
import { Accounts } from './mail/accounts';
import { startSyncLoop } from './mail/scheduler';
import { MailService } from './mail/service';
import { TriageService } from './triage/service';

const RETRY_EVERY_MS = 10 * 60_000;

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
const catalog = await loadCatalog({
  bots: config.botsDirs,
  skills: config.skillsDirs,
});
const triage = new TriageService({
  db,
  mail,
  catalog,
  bot: config.triageBot,
  language: config.language,
  runner: new FallbackRunner(
    config.agents.map(({ name, command }) =>
      name === 'claude'
        ? new ClaudeCliRunner(command)
        : new CodexCliRunner(command),
    ),
  ),
});
const onArrived = (ids: string[]) => void triage.enqueue(ids);

const app = createApp({
  version: process.env.npm_package_version ?? 'dev',
  db,
  mail,
  events,
  accounts,
  triage,
  catalog,
  onArrived,
});

startSyncLoop(mail, onArrived);
void triage.retryUntriaged();
setInterval(() => void triage.retryUntriaged(), RETRY_EVERY_MS).unref();

serve(
  { fetch: app.fetch, port: config.port, hostname: config.host },
  (info) => {
    console.log(
      `burrow server listening on http://${info.address}:${info.port}`,
    );
    console.log(`public URL for OAuth: ${config.publicUrl}`);
    console.log(
      `bots: ${[...catalog.bots.keys()].join(', ')}; triage by ${config.triageBot} via ${config.agents.map((a) => a.name).join(' then ')}`,
    );
  },
);
