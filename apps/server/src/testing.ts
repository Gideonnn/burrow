import type { MailProvider, Right, TriageDecision } from '@burrow/contracts';
import { FakeProvider } from '@burrow/hedwig';
import { createKey, createPerson } from './access/service';
import type { AgentRequest } from './agents/runner';
import { createApp } from './app';
import { openDb } from './db/client';
import { mailboxes } from './db/schema';
import { EventBus } from './events';
import { MailService } from './mail/service';
import { TriageService } from './triage/service';

// A fresh in-memory household for one test: an app, a database, a fake
// provider per mailbox, and helpers that create people, mailboxes and keys
// and call the API with them.
export function testHousehold() {
  const db = openDb(':memory:');
  const events = new EventBus();
  const providers = new Map<string, FakeProvider>();
  const mail = new MailService(
    db,
    (box) => {
      let fake = providers.get(box.id);
      if (!fake) providers.set(box.id, (fake = new FakeProvider()));
      return fake;
    },
    events,
  );
  // The bot's answers, consumed in order; an Error makes that run fail.
  const decisions: (TriageDecision | Error)[] = [];
  const agentRequests: AgentRequest[] = [];
  const triage = new TriageService({
    db,
    mail,
    bot: 'kreacher',
    catalog: {
      bots: new Map([
        [
          'kreacher',
          {
            name: 'kreacher',
            displayName: 'Kreacher',
            description: 'Sorts mail.',
            model: 'haiku',
            skills: ['sorting-hat'],
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
      ]),
    },
    runner: {
      name: 'fake',
      run: async (request) => {
        agentRequests.push(request);
        const next = decisions.shift();
        if (!next || next instanceof Error)
          throw next ?? new Error('no decision queued');
        return next;
      },
    },
  });
  const arrived: string[] = [];
  const app = createApp({
    version: 'test',
    db,
    mail,
    events,
    triage,
    onArrived: (ids) => arrived.push(...ids),
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
  ) => createKey(db, { personId, name: 'test key', rights, mailboxIds }).token;

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
    mail,
    events,
    arrived,
    triage,
    decisions,
    agentRequests,
    person,
    mailbox,
    provider,
    key,
    call,
  };
}
