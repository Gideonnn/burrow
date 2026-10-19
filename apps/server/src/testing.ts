import type { MailProvider, Right } from '@burrow/contracts';
import { FakeProvider } from '@burrow/hedwig';
import { createKey, createPerson } from './access/service';
import { createApp } from './app';
import { openDb } from './db/client';
import { mailboxes } from './db/schema';
import { EventBus } from './events';
import { MailService } from './mail/service';

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
  const arrived: string[] = [];
  const app = createApp({
    version: 'test',
    db,
    mail,
    events,
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
    person,
    mailbox,
    provider,
    key,
    call,
  };
}
