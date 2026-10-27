import type { Right } from '@burrow/contracts';
import { FakeProvider, type OAuthSession } from '@burrow/hedwig';
import { Accounts, mailboxes } from '@burrow/hedwig/server';
import { createKey, SecretBox } from '@burrow/platform';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

function setup() {
  const tokenRequests: URLSearchParams[] = [];
  // What Google answers next: a token, or that the refresh token is revoked.
  const google = { revoked: false, expiresIn: 3600 };
  const fetchFn = (async (_url: string, init: RequestInit) => {
    tokenRequests.push(new URLSearchParams(String(init.body)));
    if (google.revoked)
      return new Response(
        JSON.stringify({
          error: 'invalid_grant',
          error_description: 'Token has been expired or revoked.',
        }),
        { status: 400 },
      );
    return new Response(
      JSON.stringify({
        access_token: 'at',
        refresh_token: 'refresh-token-very-secret',
        expires_in: google.expiresIn,
      }),
    );
  }) as unknown as typeof fetch;
  const fake = new FakeProvider();
  fake.address = async () => 'jane@example.com';
  // Like the real client, every change at Gmail first asks for a token.
  let session: OAuthSession | undefined;
  const apply = fake.apply.bind(fake);
  fake.apply = async (id, ops) => {
    await session?.accessToken();
    return apply(id, ops);
  };
  const box = new SecretBox(SecretBox.generateKey());
  const h = testHousehold({
    accounts: (db) =>
      new Accounts({
        db,
        box,
        publicUrl: 'https://burrow.example',
        apps: { gmail: { clientId: 'cid', clientSecret: 'secret' } },
        fetchFn,
        clients: {
          gmail: (s) => {
            session = s as OAuthSession;
            return fake;
          },
          fastmail: (token) => {
            const jmap = new FakeProvider();
            jmap.address = async () => {
              if (token !== 'fmu1-good-token')
                throw new Error('401 unauthorized');
              return 'jane@fastmail.example';
            };
            return jmap;
          },
        },
      }),
  });
  const { db, app } = h;
  const jane = h.person('Jane');
  const keyFor = (name: string, rights: Right[]) =>
    createKey(db, {
      personId: jane.id,
      name,
      rights,
      mailboxIds: null,
      restrictions: {},
    }).token;
  const admin = keyFor('admin', ['admin']);
  const reader = keyFor('reader', ['read']);
  const post = (token: string, body: object) =>
    app.request('/api/admin/accounts/connect', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(body),
    });
  return {
    h,
    db,
    app,
    box,
    jane,
    admin,
    reader,
    keyFor,
    post,
    tokenRequests,
    google,
    fake,
  };
}

async function startLink(
  s: ReturnType<typeof setup>,
  request = () => s.post(s.admin, { personId: s.jane.id, provider: 'gmail' }),
) {
  const { url } = (await (await request()).json()) as { url: string };
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
    expect(row?.credentials).not.toContain('refresh-token-very-secret');
    expect(s.box.open(row!.credentials)).toMatchObject({
      refreshToken: 'refresh-token-very-secret',
    });
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

describe('listing the providers an admin can connect', () => {
  const get = (s: ReturnType<typeof setup>, key: string) =>
    s.app.request('/api/admin/accounts/providers', {
      headers: { authorization: `Bearer ${key}` },
    });

  it('names only the OAuth providers configured on the server, plus Fastmail', async () => {
    const s = setup();
    const res = await get(s, s.admin);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ providers: ['gmail', 'fastmail'] });
  });

  it('needs the admin right', async () => {
    const s = setup();
    expect((await get(s, s.reader)).status).toBe(403);
  });
});

describe('connecting a Fastmail account', () => {
  const add = (s: ReturnType<typeof setup>, token: string, key = s.admin) =>
    s.app.request('/api/admin/accounts/fastmail', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${key}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ personId: s.jane.id, token }),
    });

  it('checks the token with Fastmail and stores it sealed', async () => {
    const s = setup();
    const res = await add(s, 'fmu1-good-token');
    expect(res.status).toBe(201);
    const [row] = s.db.select().from(mailboxes).all();
    expect(row).toMatchObject({
      provider: 'fastmail',
      address: 'jane@fastmail.example',
    });
    expect(row?.credentials).not.toContain('fmu1-good-token');
  });

  it('refuses a token Fastmail rejects, without storing anything', async () => {
    const s = setup();
    expect((await add(s, 'fmu1-wrong-token')).status).toBe(400);
    expect(s.db.select().from(mailboxes).all()).toEqual([]);
  });

  it('needs the admin right', async () => {
    const s = setup();
    expect((await add(s, 'fmu1-good-token', s.reader)).status).toBe(403);
  });
});

describe('logging in again after Google revoked the login', () => {
  const call = (
    s: ReturnType<typeof setup>,
    key: string,
    path: string,
    body?: object,
  ) =>
    s.app.request(path, {
      method: body ? 'POST' : 'GET',
      headers: {
        authorization: `Bearer ${key}`,
        'content-type': 'application/json',
      },
      body: body ? JSON.stringify(body) : undefined,
    });

  async function revoked() {
    const s = setup();
    const owner = s.keyFor('mac', ['read', 'organize']);
    // A token that is due at once, so the next change at Gmail refreshes it.
    s.google.expiresIn = 0;
    await s.app.request(`/oauth/callback?code=c&state=${await startLink(s)}`);
    s.fake.deliver({ subject: 'Zin in eten?' });
    const [box] = s.db.select().from(mailboxes).all();
    await call(s, owner, `/api/mailboxes/${box!.id}/sync`, {});
    const [message] = (await (
      await call(s, owner, `/api/mailboxes/${box!.id}/messages?folder=inbox`)
    ).json()) as { id: string }[];
    s.google.revoked = true;
    s.google.expiresIn = 3600;
    const needsReconnect = async () =>
      (
        (await (await call(s, owner, '/api/me')).json()) as {
          mailboxes: { needsReconnect: boolean }[];
        }
      ).mailboxes[0]!.needsReconnect;
    const reconnect = () =>
      call(s, owner, `/api/mailboxes/${box!.id}/reconnect`, {});
    return {
      s,
      owner,
      box: box!,
      message: message!,
      needsReconnect,
      reconnect,
    };
  }

  it('says so when a change fails, and marks the mailbox', async () => {
    const { s, owner, message, needsReconnect } = await revoked();
    expect(await needsReconnect()).toBe(false);
    const res = await call(s, owner, `/api/messages/${message.id}/actions`, {
      ops: [{ op: 'markRead' }],
    });
    expect(res.status).toBe(409);
    expect(await needsReconnect()).toBe(true);
  });

  it('clears the mark once the owner logs in again as the same address', async () => {
    const { s, owner, message, needsReconnect, reconnect } = await revoked();
    await call(s, owner, `/api/messages/${message.id}/actions`, {
      ops: [{ op: 'markRead' }],
    });
    s.google.revoked = false;
    const done = await s.app.request(
      `/oauth/callback?code=c&state=${await startLink(s, reconnect)}`,
    );
    expect(done.status).toBe(200);
    expect(await needsReconnect()).toBe(false);
    expect(
      (
        await call(s, owner, `/api/messages/${message.id}/actions`, {
          ops: [{ op: 'markRead' }],
        })
      ).status,
    ).toBe(200);
  });

  it('refuses a login as another address', async () => {
    const { s, owner, message, needsReconnect, reconnect } = await revoked();
    await call(s, owner, `/api/messages/${message.id}/actions`, {
      ops: [{ op: 'markRead' }],
    });
    s.google.revoked = false;
    s.fake.address = async () => 'someone-else@example.com';
    const done = await s.app.request(
      `/oauth/callback?code=c&state=${await startLink(s, reconnect)}`,
    );
    expect(done.status).toBe(400);
    expect(await needsReconnect()).toBe(true);
    expect(s.db.select().from(mailboxes).all()).toHaveLength(1);
  });

  it('gives the link only to the owner', async () => {
    const { s, box } = await revoked();
    const john = createKey(s.db, {
      personId: s.h.person('John').id,
      name: 'john',
      rights: ['read', 'organize'],
      mailboxIds: null,
      restrictions: {},
    }).token;
    expect(
      (await call(s, john, `/api/mailboxes/${box.id}/reconnect`, {})).status,
    ).toBe(404);
  });
});
