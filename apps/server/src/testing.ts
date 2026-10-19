import { mkdtempSync } from 'node:fs';
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
          skills: ['sorting-hat', 'reply-suggestions'],
          rights: ['read', 'organize', 'draft'],
          persona: 'You are Kreacher.',
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
    decisions,
    agentRequests,
    person,
    mailbox,
    provider,
    key,
    call,
  };
}
