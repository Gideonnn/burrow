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
import {
  type Audio,
  pensieveModule,
  type TranscribeOptions,
  type Transcriber,
  type Transcription,
} from '@burrow/pensieve';
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
  // Pages and pictures on the internet by URL, for the outings' pictures.
  const web = new Map<
    string,
    { contentType: string; body: Uint8Array | string }
  >();
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
          skills: [
            'sorting-hat',
            'reply-suggestions',
            'mail-search',
            'mail-templates',
            'meeting-notes',
            'interview-notes',
            'screen-steps',
            'outing-details',
            'festival-lineup',
          ],
          rights: ['read', 'organize', 'draft'],
          persona: 'You are Kreacher.',
        },
      ],
      [
        'winky',
        {
          name: 'winky',
          displayName: 'Winky',
          description: 'Reads sensitive mail locally.',
          model: 'ollama:gemma4:26b-a4b',
          agent: 'local',
          skills: ['mail-facts'],
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
        'mail-facts',
        {
          name: 'mail-facts',
          description: 'Indexes one message.',
          instructions: 'Index it.',
        },
      ],
      [
        'mail-templates',
        {
          name: 'mail-templates',
          description: 'Indexes templates.',
          instructions: 'Index them.',
        },
      ],
      [
        'festival-lineup',
        {
          name: 'festival-lineup',
          description: 'Reads a line-up.',
          instructions: 'Read the line-up.',
        },
      ],
      [
        'outing-details',
        {
          name: 'outing-details',
          description: 'Reads an order mail.',
          instructions: 'Read the outing.',
        },
      ],
      [
        'meeting-notes',
        {
          name: 'meeting-notes',
          description: 'Notes.',
          model: 'opus',
          instructions: 'Write notes.',
        },
      ],
      [
        'interview-notes',
        {
          name: 'interview-notes',
          description: 'Interview notes.',
          model: 'opus',
          instructions: 'Write interview notes.',
        },
      ],
      [
        'screen-steps',
        {
          name: 'screen-steps',
          description: 'Steps.',
          instructions: 'Write the steps.',
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
    fetchPublic: async (url, maxBytes) => {
      const page = web.get(url);
      if (!page) throw new Error('HTTP 404');
      const data =
        typeof page.body === 'string' ? Buffer.from(page.body) : page.body;
      if (data.byteLength > maxBytes) throw new Error('too large');
      return { data, contentType: page.contentType, url };
    },
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
  // transcribed part takes the next queued text or transcription (an Error
  // fails that part). Every call's options are kept.
  const transcripts: (string | Transcription | Error)[] = [];
  const transcribeCalls: TranscribeOptions[] = [];
  const audio: Audio = {
    compress: async (input, output) => {
      await copyFile(input, output);
      return { seconds: 61 };
    },
    split: async (input, dir) => {
      const file = join(dir, 'part-000.m4a');
      await copyFile(input, file);
      return [{ file, start: 0 }];
    },
  };
  const transcriber: Transcriber = {
    name: 'fake',
    maxSeconds: 1200,
    transcribe: async (_file, options) => {
      transcribeCalls.push(options);
      const next = transcripts.shift();
      if (next === undefined || next instanceof Error)
        throw next ?? new Error('no transcript queued');
      return typeof next === 'string' ? { text: next, segments: null } : next;
    },
  };
  const pensieve = pensieveModule(platform, {
    audio,
    transcriber,
    bot: 'kreacher',
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
    factsOnly = false,
  ) =>
    createKey(
      db,
      {
        personId,
        name: 'test key',
        rights,
        mailboxIds,
        restrictions: {},
        factsOnly,
      },
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
    facts: hedwig.facts,
    outings: hedwig.outings,
    routines: platform.routines,
    workers: platform.workers,
    arrived,
    recordings: pensieve.recordings,
    transcripts,
    transcribeCalls,
    decisions,
    agentRequests,
    web,
    person,
    mailbox,
    provider,
    key,
    call,
  };
}
