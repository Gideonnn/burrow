import { resolve } from 'node:path';
import { serve } from '@hono/node-server';
import {
  ClaudeCliRunner,
  CodexCliRunner,
  FallbackRunner,
} from './agents/runner';
import { createApp } from './app';
import { behindCloudflareAccess } from './auth/cloudflareAccess';
import { loadCatalog } from './catalog/loadCatalog';
import { loadConfig } from './config';
import { SecretBox } from './crypto/secretBox';
import { openDb } from './db/client';
import { EventBus } from './events';
import { Accounts } from './mail/accounts';
import { startSyncLoop } from './mail/scheduler';
import { MailService } from './mail/service';
import { RoutineService } from './routines/service';
import { InsightsService, LONG_MESSAGE } from './triage/insights';
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
const runner = new FallbackRunner(
  config.agents.map(({ name, command }) =>
    name === 'claude'
      ? new ClaudeCliRunner(command)
      : new CodexCliRunner(command),
  ),
);
const insights = new InsightsService({
  db,
  mail,
  catalog,
  runner,
  bot: config.triageBot,
  language: config.language,
});
const routines = new RoutineService({
  db,
  mail,
  catalog,
  runner,
  language: config.language,
});
const triage = new TriageService({
  db,
  mail,
  catalog,
  runner,
  bot: config.triageBot,
  language: config.language,
  // Suggestions are ready by the time someone opens mail that needs an
  // answer, and long mail gets its summary up front.
  onDecided: (messageId, decision) => {
    const body = mail.message(messageId)?.bodyText ?? '';
    if (decision.action.kind === 'needs-reply' || body.length > LONG_MESSAGE) {
      insights.prefetch(messageId);
    }
    routines.onTriaged(messageId, decision);
  },
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
  insights,
  routines,
  onArrived,
  clientsDir: resolve(config.dataDir, 'clients'),
});

startSyncLoop(mail, onArrived);
void triage.retryUntriaged();
setInterval(() => void triage.retryUntriaged(), RETRY_EVERY_MS).unref();
setInterval(() => routines.tick(), 60_000).unref();

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

if (config.cloudflareAccess) {
  const { team, audience, port } = config.cloudflareAccess;
  const tunnel = behindCloudflareAccess(app, { db, team, audience });
  serve({ fetch: tunnel.fetch, port, hostname: config.host }, (info) =>
    console.log(
      `for the Cloudflare Tunnel, behind Access: http://${info.address}:${info.port}`,
    ),
  );
}
