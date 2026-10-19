import type { MailProvider, Right } from '@burrow/contracts';
import { createKey, createPerson } from './access/service';
import { createApp } from './app';
import { openDb } from './db/client';
import { mailboxes } from './db/schema';

// A fresh in-memory household for one test: an app, a database and helpers
// that create people, mailboxes and keys and call the API with them.
export function testHousehold() {
  const db = openDb(':memory:');
  const app = createApp({ version: 'test', db });

  const person = (name: string) => createPerson(db, name);

  const mailbox = (
    ownerId: string,
    address: string,
    provider: MailProvider = 'gmail',
  ) =>
    db
      .insert(mailboxes)
      .values({ ownerId, provider, address, name: address, credentials: 'x' })
      .returning()
      .get();

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

  return { db, app, person, mailbox, key, call };
}
