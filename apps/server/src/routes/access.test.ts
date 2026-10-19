import { createKeyResponse, meResponse } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

function household() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const work = h.mailbox(gideon.id, 'gideon@work.example', 'microsoft');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  return { ...h, gideon, eva, work, home, evas };
}

describe('API keys', () => {
  it('rejects a request without a key or with an unknown key', async () => {
    const h = household();
    expect((await h.app.request('/api/me')).status).toBe(401);
    expect((await h.call('bk_nope', '/api/me')).status).toBe(401);
  });

  it('shows a key only the mailboxes it was given', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read'], [h.home.id]);
    const me = meResponse.parse(await (await h.call(token, '/api/me')).json());
    expect(me.mailboxes.map((m) => m.address)).toEqual(['gideon@example.com']);
  });

  it('gives a key without a mailbox list every mailbox of its person, and only those', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read']);
    const me = meResponse.parse(await (await h.call(token, '/api/me')).json());
    expect(me.mailboxes.map((m) => m.address).sort()).toEqual([
      'gideon@example.com',
      'gideon@work.example',
    ]);
  });

  it('includes a mailbox added after the key was made', async () => {
    const h = household();
    const token = h.key(h.eva.id, ['read']);
    h.mailbox(h.eva.id, 'eva@work.example');
    const me = meResponse.parse(await (await h.call(token, '/api/me')).json());
    expect(me.mailboxes).toHaveLength(2);
  });

  it('stops working as soon as it is revoked', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['admin']);
    const created = createKeyResponse.parse(
      await (
        await h.call(admin, '/api/admin/keys', {
          method: 'POST',
          body: JSON.stringify({
            personId: h.gideon.id,
            name: 'MacBook Gideon',
            rights: ['read'],
          }),
        })
      ).json(),
    );
    expect((await h.call(created.token, '/api/me')).status).toBe(200);
    await h.call(admin, `/api/admin/keys/${created.key.id}`, {
      method: 'DELETE',
    });
    expect((await h.call(created.token, '/api/me')).status).toBe(401);
  });
});

describe('admin routes', () => {
  it('are closed to a key without the admin right', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read', 'organize', 'send']);
    expect((await h.call(token, '/api/admin/keys')).status).toBe(403);
  });

  it('refuse a key that includes another person’s mailbox', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['admin']);
    const res = await h.call(admin, '/api/admin/keys', {
      method: 'POST',
      body: JSON.stringify({
        personId: h.gideon.id,
        name: 'sneaky',
        rights: ['read'],
        mailboxIds: [h.evas.id, h.work.id],
      }),
    });
    expect(res.status).toBe(400);
  });

  // A key reads its person's mail, so an admin making one for someone else
  // could read their mail; that person logs in on their own device instead.
  it('refuse a key for another person, even to an admin', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['admin']);
    const res = await h.call(admin, '/api/admin/keys', {
      method: 'POST',
      body: JSON.stringify({
        personId: h.eva.id,
        name: 'Mac Eva',
        rights: ['read'],
      }),
    });
    expect(res.status).toBe(403);
  });

  it('never return a key hash or token in the list', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['admin']);
    const other = h.key(h.eva.id, ['read']);
    const body = await (await h.call(admin, '/api/admin/keys')).text();
    expect(body).not.toContain('"hash"');
    expect(body).not.toContain(admin);
    expect(body).not.toContain(other);
  });

  it('do not let a key revoke itself', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['admin']);
    const me = meResponse.parse(await (await h.call(admin, '/api/me')).json());
    const res = await h.call(admin, `/api/admin/keys/${me.key.id}`, {
      method: 'DELETE',
    });
    expect(res.status).toBe(400);
  });
});

describe('mailbox name and role', () => {
  it('starts as private and can be renamed and given a role by its owner', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    let me = meResponse.parse(await (await h.call(token, '/api/me')).json());
    expect(me.mailboxes.find((m) => m.id === h.work.id)?.role).toBe('private');

    const res = await h.call(token, `/api/mailboxes/${h.work.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ name: 'Werk', role: 'work' }),
    });
    expect(res.status).toBe(200);
    me = meResponse.parse(await (await h.call(token, '/api/me')).json());
    expect(me.mailboxes.find((m) => m.id === h.work.id)).toMatchObject({
      name: 'Werk',
      role: 'work',
    });
  });

  it('cannot be changed through a key that does not see the mailbox or may not organize', async () => {
    const h = household();
    const patch = (token: string, body: object) =>
      h.call(token, `/api/mailboxes/${h.evas.id}`, {
        method: 'PATCH',
        body: JSON.stringify(body),
      });
    expect(
      (await patch(h.key(h.gideon.id, ['read', 'organize']), { role: 'work' }))
        .status,
    ).toBe(404);
    expect(
      (await patch(h.key(h.eva.id, ['read']), { role: 'school' })).status,
    ).toBe(403);
    expect(
      (await patch(h.key(h.eva.id, ['read', 'organize']), { role: 'hobby' }))
        .status,
    ).toBe(400);
  });
});
