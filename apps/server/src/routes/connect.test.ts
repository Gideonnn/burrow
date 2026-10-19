import { FakeProvider } from '@burrow/hedwig';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { createKey, createPerson } from '../access/service';
import { createApp } from '../app';
import { SecretBox } from '../crypto/secretBox';
import { openDb } from '../db/client';
import { mailboxes } from '../db/schema';
import { EventBus } from '../events';
import { Accounts } from '../mail/accounts';
import { MailService } from '../mail/service';

function setup() {
  const db = openDb(':memory:');
  const tokenRequests: URLSearchParams[] = [];
  const fetchFn = (async (_url: string, init: RequestInit) => {
    tokenRequests.push(new URLSearchParams(String(init.body)));
    return new Response(
      JSON.stringify({
        access_token: 'at',
        refresh_token: 'rt',
        expires_in: 3600,
      }),
    );
  }) as unknown as typeof fetch;
  const fake = new FakeProvider();
  fake.address = async () => 'jane@example.com';
  const box = new SecretBox(SecretBox.generateKey());
  const accounts = new Accounts({
    db,
    box,
    publicUrl: 'https://burrow.example',
    apps: { gmail: { clientId: 'cid', clientSecret: 'secret' } },
    fetchFn,
    clients: { gmail: () => fake },
  });
  const events = new EventBus();
  const app = createApp({
    version: 'test',
    db,
    events,
    accounts,
    mail: new MailService(db, accounts.clientFor, events),
  });
  const jane = createPerson(db, 'Jane');
  const admin = createKey(db, {
    personId: jane.id,
    name: 'admin',
    rights: ['admin'],
    mailboxIds: null,
  }).token;
  const reader = createKey(db, {
    personId: jane.id,
    name: 'reader',
    rights: ['read'],
    mailboxIds: null,
  }).token;
  const post = (token: string, body: object) =>
    app.request('/api/admin/accounts/connect', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(body),
    });
  return { db, app, box, jane, admin, reader, post, tokenRequests };
}

async function startLink(s: ReturnType<typeof setup>) {
  const { url } = (await (
    await s.post(s.admin, { personId: s.jane.id, provider: 'gmail' })
  ).json()) as { url: string };
  expect(url).toMatch(/^https:\/\/burrow\.example\/oauth\/start\//);
  const start = await s.app.request(new URL(url).pathname);
  expect(start.status).toBe(302);
  const google = new URL(start.headers.get('location')!);
  expect(google.origin).toBe('https://accounts.google.com');
  expect(google.searchParams.get('redirect_uri')).toBe(
    'https://burrow.example/oauth/callback',
  );
  return google.searchParams.get('state')!;
}

describe('connecting a Gmail account', () => {
  it('stores the mailbox for the chosen person with sealed credentials', async () => {
    const s = setup();
    const state = await startLink(s);
    const done = await s.app.request(
      `/oauth/callback?code=the-code&state=${state}`,
    );
    expect(done.status).toBe(200);
    expect(await done.text()).toContain('jane@example.com is gekoppeld');
    expect(s.tokenRequests[0]?.get('code')).toBe('the-code');
    expect(s.tokenRequests[0]?.get('code_verifier')).toBeTruthy();

    const [row] = s.db
      .select()
      .from(mailboxes)
      .where(eq(mailboxes.ownerId, s.jane.id))
      .all();
    expect(row?.address).toBe('jane@example.com');
    expect(row?.credentials).not.toContain('rt');
    expect(s.box.open(row!.credentials)).toMatchObject({ refreshToken: 'rt' });
  });

  it('replaces credentials instead of adding a duplicate when connected twice', async () => {
    const s = setup();
    for (const _ of [1, 2]) {
      const state = await startLink(s);
      await s.app.request(`/oauth/callback?code=c&state=${state}`);
    }
    expect(s.db.select().from(mailboxes).all()).toHaveLength(1);
  });

  it('accepts each link only once', async () => {
    const s = setup();
    const state = await startLink(s);
    await s.app.request(`/oauth/callback?code=c&state=${state}`);
    expect(
      (await s.app.request(`/oauth/callback?code=c&state=${state}`)).status,
    ).toBe(410);
  });

  it('rejects an unknown state', async () => {
    const s = setup();
    expect(
      (await s.app.request('/oauth/callback?code=c&state=forged')).status,
    ).toBe(410);
  });

  it('needs the admin right and a configured provider', async () => {
    const s = setup();
    expect(
      (await s.post(s.reader, { personId: s.jane.id, provider: 'gmail' }))
        .status,
    ).toBe(403);
    expect(
      (await s.post(s.admin, { personId: s.jane.id, provider: 'microsoft' }))
        .status,
    ).toBe(400);
  });
});
