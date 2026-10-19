import {
  householdMember,
  settingDefinition,
  settingsValues,
} from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

function household() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  const send = (token: string, method: string, path: string, body: unknown) =>
    h.call(token, path, { method, body: JSON.stringify(body) });
  return { ...h, gideon, eva, evas, send };
}

describe('settings', () => {
  it('lists what every module offers, with Hedwig’s features', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read']);
    const schema = z
      .array(settingDefinition)
      .parse(await (await h.call(token, '/api/settings/schema')).json());
    expect(schema.filter((s) => s.feature).map((s) => s.key)).toEqual(
      expect.arrayContaining(['hedwig.enabled', 'hedwig.triage']),
    );
  });

  it('lets a person change their own and reset them to the default', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    const changed = settingsValues.parse(
      await (
        await h.send(token, 'PATCH', '/api/me/settings', {
          values: { 'hedwig.triage': false, language: 'Dutch' },
        })
      ).json(),
    );
    expect(changed).toMatchObject({
      'hedwig.triage': false,
      language: 'Dutch',
    });
    const me = await (await h.call(token, '/api/me')).json();
    expect(me).toMatchObject({ language: 'Dutch', admin: true });

    await h.send(token, 'PATCH', '/api/me/settings', {
      values: { 'hedwig.triage': null },
    });
    const after = settingsValues.parse(
      await (await h.call(token, '/api/me/settings')).json(),
    );
    expect(after['hedwig.triage']).toBe(true);
  });

  it('refuses unknown settings and values of the wrong kind', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    for (const values of [
      { 'hedwig.nonsense': true },
      { 'hedwig.triage': 'yes' },
      { language: 'Klingon' },
    ]) {
      expect(
        (await h.send(token, 'PATCH', '/api/me/settings', { values })).status,
      ).toBe(400);
    }
  });

  it('stops the bot from sorting mail for a person who switched it off', async () => {
    const h = household();
    const token = h.key(h.eva.id, ['read', 'organize']);
    await h.send(token, 'PATCH', '/api/me/settings', {
      values: { 'hedwig.triage': false },
    });
    h.provider(h.evas.id).deliver({ subject: 'Nieuwsbrief' });
    await h.triage.enqueue(await h.mail.sync(h.evas.id));
    expect(h.agentRequests).toHaveLength(0);
  });
});

describe('the household', () => {
  it('lets an admin manage the other person’s settings and see their devices', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['read', 'admin']);
    h.key(h.eva.id, ['read']);
    const changed = await h.send(
      admin,
      'PATCH',
      `/api/admin/people/${h.eva.id}/settings`,
      { values: { 'hedwig.insights': false } },
    );
    expect(changed.status).toBe(200);
    const people = z
      .array(householdMember)
      .parse(await (await h.call(admin, '/api/admin/people')).json());
    const eva = people.find((p) => p.name === 'Eva')!;
    expect(eva.settings['hedwig.insights']).toBe(false);
    expect(eva.keys).toHaveLength(1);
  });

  it('never lets an admin read the other person’s mail', async () => {
    const h = household();
    const admin = h.key(h.gideon.id, ['read', 'admin']);
    h.provider(h.evas.id).deliver({ subject: 'Privé' });
    await h.mail.sync(h.evas.id);
    const list = await h.call(admin, `/api/mailboxes/${h.evas.id}/messages`);
    expect(list.status).toBe(404);
    const people = await (await h.call(admin, '/api/admin/people')).text();
    expect(people).not.toContain('Privé');
  });

  it('keeps settings of others closed to keys without the admin right', async () => {
    const h = household();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    const res = await h.send(
      token,
      'PATCH',
      `/api/admin/people/${h.eva.id}/settings`,
      { values: { 'hedwig.triage': false } },
    );
    expect(res.status).toBe(403);
  });
});
