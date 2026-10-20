import { mkdtempSync } from 'node:fs';
import { copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type {
  MailProvider,
  MessageInsights,
  Right,
  TriageDecision,
} from '@burrow/contracts';
import { FakeProvider } from '@burrow/hedwig';
import { type Accounts, hedwigModule, mailboxes } from '@burrow/hedwig/server';
import { type Audio, pensieveModule, type Transcriber } from '@burrow/pensieve';
import {
  type AgentRequest,
  type AgentRunner,
  type Catalog,
  createKey,
  createPerson,
  type Db,
  Platform,
} from '@burrow/platform';
import { createApp } from './app';
import { openDb } from './db/client';

// A fresh in-memory household for one test: an app, a database, a fake
// provider per mailbox, and helpers that create people, mailboxes and keys
// and call the API with them.
export function testHousehold({
  clientsDir,
  devLoginAs,
  accounts: makeAccounts,
}: {
  clientsDir?: string;
  devLoginAs?: string;
  // Real accounts (with fake provider clients inside) instead of fakes.
  accounts?: (db: Db) => Accounts;
} = {}) {
  const db = openDb(':memory:');
  const providers = new Map<string, FakeProvider>();
  // The bot's answers, consumed in order; an Error makes that run fail.
  const decisions: (TriageDecision | MessageInsights | object | Error)[] = [];
  const agentRequests: AgentRequest[] = [];
  const catalog: Catalog = {
    bots: new Map([
      [
        'kreacher',
        {
          name: 'kreacher',
          displayName: 'Kreacher',
          description: 'Sorts mail.',
          model: 'haiku',
          agent: 'claude',
          skills: ['sorting-hat', 'reply-suggestions', 'mail-search'],
          rights: ['read', 'organize', 'draft'],
          persona: 'You are Kreacher.',
        },
      ],
      [
        'winky',
        {
          name: 'winky',
          displayName: 'Winky',
          description: 'Writes notes.',
          model: 'sonnet',
          agent: 'any',
          skills: ['meeting-notes'],
          rights: ['read'],
          persona: 'You are Winky.',
        },
      ],
    ]),
    skills: new Map([
      [
        'sorting-hat',
        {
          name: 'sorting-hat',
          description: 'Sorts.',
          instructions: 'Sort it.',
        },
      ],
      [
        'reply-suggestions',
        {
          name: 'reply-suggestions',
          description: 'Suggests.',
          instructions: 'Suggest replies.',
        },
      ],
      [
        'mail-search',
        {
          name: 'mail-search',
          description: 'Plans a search.',
          instructions: 'Plan the search.',
        },
      ],
      [
        'meeting-notes',
        {
          name: 'meeting-notes',
          description: 'Notes.',
          instructions: 'Write notes.',
        },
      ],
    ]),
  };
  const runner: AgentRunner = {
    name: 'fake',
    run: async (request) => {
      agentRequests.push(request);
      const next = decisions.shift();
      if (!next || next instanceof Error)
        throw next ?? new Error('no decision queued');
      return next;
    },
  };
  const dataDir = mkdtempSync(join(tmpdir(), 'burrow-test-'));
  const platform = new Platform({
    db,
    dataDir,
    publicUrl: 'https://burrow.example.com',
    catalog,
    runner,
  });
  const accounts = makeAccounts?.(db);
  const arrived: string[] = [];
  const hedwig = hedwigModule(platform, {
    bot: 'kreacher',
    sync: false,
    accounts,
    onArrived: (ids) => arrived.push(...ids),
    clientFor:
      accounts?.clientFor ??
      ((box) => {
        let fake = providers.get(box.id);
        if (!fake) providers.set(box.id, (fake = new FakeProvider()));
        return fake;
      }),
  });
  platform.use(hedwig.module);
  // Stand-ins for ffmpeg and OpenAI: compressing copies the file, and each
  // transcribed part takes the next queued text (an Error fails that part).
  const transcripts: (string | Error)[] = [];
  const audio: Audio = {
    compress: async (input, output) => {
      await copyFile(input, output);
      return { seconds: 61 };
    },
    split: async (input, dir) => {
      const part = join(dir, 'part-000.m4a');
      await copyFile(input, part);
      return [part];
    },
  };
  const transcriber: Transcriber = {
    name: 'fake',
    maxSeconds: 1200,
    transcribe: async () => {
      const next = transcripts.shift();
      if (next === undefined || next instanceof Error)
        throw next ?? new Error('no transcript queued');
      return next;
    },
  };
  const pensieve = pensieveModule(platform, {
    audio,
    transcriber,
    bot: 'winky',
  });
  platform.use(pensieve.module);
  const app = createApp({
    version: 'test',
    platform,
    clientsDir,
    devLoginAs,
  });

  const person = (name: string) => createPerson(db, name);

  const mailbox = (
    ownerId: string,
    address: string,
    provider: MailProvider = 'gmail',
  ) => {
    const row = db
      .insert(mailboxes)
      .values({ ownerId, provider, address, name: address, credentials: 'x' })
      .returning()
      .get();
    providers.set(row.id, new FakeProvider());
    return row;
  };

  const provider = (mailboxId: string) => providers.get(mailboxId)!;

  const key = (
    personId: string,
    rights: Right[],
    mailboxIds: string[] | null = null,
  ) =>
    createKey(
      db,
      { personId, name: 'test key', rights, mailboxIds, restrictions: {} },
      platform.restrictionChecks,
    ).token;

  const call = (token: string, path: string, init: RequestInit = {}) =>
    app.request(path, {
      ...init,
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        ...init.headers,
      },
    });

  return {
    db,
    app,
    platform,
    dataDir,
    mail: hedwig.mail,
    events: platform.events,
    triage: hedwig.triage,
    insights: hedwig.insights,
    routines: platform.routines,
    workers: platform.workers,
    arrived,
    recordings: pensieve.recordings,
    transcripts,
    decisions,
    agentRequests,
    person,
    mailbox,
    provider,
    key,
    call,
  };
}
