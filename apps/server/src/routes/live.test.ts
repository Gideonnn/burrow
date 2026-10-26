import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

// Settings and the household change on one Mac and show on the others at
// once: the server says so on the event stream, to the right people.

describe('live settings and household', () => {
  it('tells the person, and only them, that a setting changed', async () => {
    const h = testHousehold();
    const ada = h.person('Ada');
    const bram = h.person('Bram');
    const adaKey = h.key(ada.id, ['read', 'organize']);
    const seen: string[] = [];
    h.events.subscribe((e) => {
      if (e.data.type !== 'settings.changed') return;
      for (const person of [ada, bram]) {
        if (e.visibleTo({ personId: person.id } as never))
          seen.push(person.name);
      }
    });
    const res = await h.call(adaKey, '/api/me/settings', {
      method: 'PATCH',
      body: JSON.stringify({ values: { 'lumos.enabled': false } }),
    });
    expect(res.status).toBe(200);
    expect(seen).toEqual(['Ada']);
  });

  it('tells everyone when a person or a key comes or goes', async () => {
    const h = testHousehold();
    const ada = h.person('Ada');
    const admin = h.key(ada.id, ['read', 'organize', 'admin']);
    const seen: string[] = [];
    h.events.subscribe((e) => {
      if (e.data.type === 'household.changed')
        seen.push(String(e.visibleTo({ personId: 'anyone' } as never)));
    });
    const made = await h.call(admin, '/api/admin/people', {
      method: 'POST',
      body: JSON.stringify({ name: 'Eva' }),
    });
    expect(made.status).toBe(201);
    const other = h.key(ada.id, ['read']);
    const keys = (await (await h.call(admin, '/api/admin/keys')).json()) as {
      id: string;
      name: string;
    }[];
    const target =
      keys.find((k) => k.id === other.split('.')[0]) ?? keys.at(-1);
    const revoked = await h.call(admin, `/api/admin/keys/${target?.id}`, {
      method: 'DELETE',
    });
    expect(revoked.status).toBe(200);
    expect(seen).toEqual(['true', 'true']);
  });
});
