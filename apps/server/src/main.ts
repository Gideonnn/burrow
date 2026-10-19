import { resolve } from 'node:path';
import { Accounts, hedwigModule } from '@burrow/hedwig/server';
import {
  FfmpegAudio,
  OpenAITranscriber,
  pensieveModule,
} from '@burrow/pensieve';
import {
  ClaudeCliRunner,
  CodexCliRunner,
  FallbackRunner,
  loadCatalog,
  Platform,
  SecretBox,
} from '@burrow/platform';
import { serve } from '@hono/node-server';
import { createApp } from './app';
import { behindCloudflareAccess } from './auth/cloudflareAccess';
import { loadConfig } from './config';
import { openDb } from './db/client';

const config = loadConfig();
if (!config.secretKey) {
  console.error(
    'BURROW_SECRET_KEY is not set. Generate one with `pnpm --filter @burrow/server cli generate-secret`.',
  );
  process.exit(1);
}

const db = openDb(config.dbPath);
const catalog = await loadCatalog({
  bots: config.botsDirs,
  skills: config.skillsDirs,
});
const runner = new FallbackRunner(
  config.agents.map(({ name, command }) =>
    name === 'claude'
      ? new ClaudeCliRunner(command)
      : new CodexCliRunner(command, config.codexModel),
  ),
);
const platform = new Platform({
  db,
  dataDir: config.dataDir,
  publicUrl: config.publicUrl,
  catalog,
  runner,
  language: config.language,
  workers: config.workers,
  agents: config.agentRuns,
});

const accounts = new Accounts({
  db,
  box: new SecretBox(config.secretKey),
  publicUrl: config.publicUrl,
  apps: { gmail: config.google, microsoft: config.microsoft },
});
platform.use(
  hedwigModule(platform, {
    clientFor: accounts.clientFor,
    accounts,
    bot: config.triageBot,
  }).module,
);
platform.use(
  pensieveModule(platform, {
    audio: new FfmpegAudio(config.ffmpeg, config.ffprobe),
    transcriber: config.openaiKey
      ? new OpenAITranscriber(config.openaiKey, config.transcribeModel)
      : undefined,
    bot: config.notesBot,
  }).module,
);
if (!config.openaiKey) {
  console.log('Pensieve: no OPENAI_API_KEY, so recordings are not transcribed');
}

const app = createApp({
  version: process.env.npm_package_version ?? 'dev',
  platform,
  clientsDir: resolve(config.dataDir, 'clients'),
  devLoginAs: config.devLoginAs,
  contact: config.contact,
});

platform.start();

serve(
  { fetch: app.fetch, port: config.port, hostname: config.host },
  (info) => {
    console.log(
      `burrow server listening on http://${info.address}:${info.port}`,
    );
    console.log(`public URL for OAuth and logins: ${config.publicUrl}`);
    console.log(
      `modules: ${platform.modules.map((m) => m.name).join(', ')}; bots: ${[...catalog.bots.keys()].join(', ')}; agents: ${config.agents.map((a) => a.name).join(' then ')}`,
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
