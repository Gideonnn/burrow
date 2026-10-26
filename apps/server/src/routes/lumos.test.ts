import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  browseResponse,
  creditResponse,
  listResponse,
  lumosChange,
  rowsResponse,
  titleDetail,
  titleSearchResponse,
  titlesResponse,
  verdictsResponse,
} from '@burrow/contracts';
import { type CatalogueProvider, FixtureCatalogue } from '@burrow/lumos';
import { describe, expect, it } from 'vitest';
import { loadConfig } from '../config';
import { testHousehold } from '../testing';

const PALM = { mediaType: 'movie', tmdbId: 9_000_001 } as const;
const HOLDOVERS = { mediaType: 'movie', tmdbId: 9_000_002 } as const;
const LOOP = { mediaType: 'movie', tmdbId: 9_000_019 } as const;
const SIGNAL_HILL = { mediaType: 'tv', tmdbId: 9_000_032 } as const;

function household(options: Parameters<typeof testHousehold>[0] = {}) {
  const h = testHousehold(options);
  const ada = h.person('Ada');
  const bram = h.person('Bram');
  const adaKey = h.key(ada.id, ['read', 'organize']);
  const bramKey = h.key(bram.id, ['read', 'organize']);
  const send = async (
    key: string,
    method: string,
    path: string,
    body?: unknown,
  ) =>
    h.call(key, path, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const json = async (key: string, path: string) =>
    (await h.call(key, path)).json();
  const add = async (
    key: string,
    scope: 'shared' | 'mine',
    t: { mediaType: string; tmdbId: number },
  ) => {
    const res = await send(
      key,
      'PUT',
      `/api/lumos/lists/${scope}/items/${t.mediaType}/${t.tmdbId}`,
      {},
    );
    expect(res.status).toBe(200);
    return lumosChange.parse(await res.json()).changeId;
  };
  const verdict = async (
    key: string,
    body: {
      scope: 'shared' | 'mine';
      mediaType: string;
      tmdbId: number;
      kind: string;
      reason?: string | null;
    },
  ) => {
    const res = await send(key, 'POST', '/api/lumos/verdicts', body);
    expect(res.status).toBe(201);
    return lumosChange.parse(await res.json()).changeId;
  };
  const list = async (key: string, scope: 'shared' | 'mine') =>
    listResponse.parse(await json(key, `/api/lumos/lists/${scope}`));
  const verdicts = async (key: string, scope: 'shared' | 'mine') =>
    verdictsResponse.parse(
      await json(key, `/api/lumos/verdicts?scope=${scope}`),
    );
  const rows = async (key: string, scope: 'shared' | 'mine') =>
    rowsResponse.parse(await json(key, `/api/lumos/rows?scope=${scope}`));
  const movies = async (key: string, scope: 'shared' | 'mine') =>
    titlesResponse.parse(
      await json(key, `/api/lumos/titles?type=movie&scope=${scope}`),
    );
  const row = async (key: string, scope: 'shared' | 'mine', name: string) =>
    (await rows(key, scope)).rows.find((r) => r.key === name);
  return {
    ...h,
    ada,
    bram,
    adaKey,
    bramKey,
    send,
    json,
    add,
    verdict,
    list,
    verdicts,
    rows,
    movies,
    row,
  };
}

const ids = (items: { title: { tmdbId: number } }[]) =>
  items.map((i) => i.title.tmdbId);

describe('the catalogue', () => {
  it('marks every answer from the fixtures as test data', async () => {
    const h = household();
    expect(await h.json(h.adaKey, '/api/lumos/status')).toEqual({
      dataOrigin: 'fixture',
      catalogue: 'Testgegevens',
      requests: false,
      watch: false,
    });
    const answers = [
      rowsResponse.parse(await h.json(h.adaKey, '/api/lumos/rows')),
      titleSearchResponse.parse(
        await h.json(h.adaKey, '/api/lumos/search?q=loop'),
      ),
      titleDetail.parse(
        await h.json(h.adaKey, '/api/lumos/titles/movie/9000001'),
      ),
      titlesResponse.parse(
        await h.json(h.adaKey, '/api/lumos/similar/movie/9000001'),
      ),
      titlesResponse.parse(await h.json(h.adaKey, '/api/lumos/titles')),
    ];
    for (const answer of answers) expect(answer.dataOrigin).toBe('fixture');
  });

  it('answers "niet gekoppeld" without a catalogue, while lists still work', async () => {
    const h = household({ catalogue: null });
    const res = await h.call(h.adaKey, '/api/lumos/rows');
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({
      error: 'Lumos is niet gekoppeld aan een catalogus',
    });
    expect((await h.list(h.adaKey, 'shared')).items).toEqual([]);
    expect(await h.json(h.adaKey, '/api/lumos/status')).toEqual({
      dataOrigin: null,
      catalogue: null,
      requests: false,
      watch: false,
    });
  });

  it('finds old and new titles by title and by a cast member', async () => {
    const h = household();
    const search = async (q: string) =>
      titleSearchResponse.parse(
        await h.json(h.adaKey, `/api/lumos/search?q=${encodeURIComponent(q)}`),
      );
    expect(ids((await search('midnight at the ferry')).hits)).toEqual([
      9_000_016,
    ]);
    expect(ids((await search('Loop of Tuesdays')).hits)).toEqual([9_000_019]);
    const desmond = await search('Desmond Clarke');
    expect(ids(desmond.hits)).toEqual(
      expect.arrayContaining([9_000_016, 9_000_018, 9_000_035]),
    );
    expect(desmond.hits[0]?.why).toBe('Cast: Desmond Clarke');
    expect(desmond.credits).toEqual([
      { id: 'fx-desmond-clarke', name: 'Desmond Clarke' },
    ]);
    const credit = (await h.json(
      h.adaKey,
      '/api/lumos/credits/fx-desmond-clarke',
    )) as { titles: { year: number }[] };
    expect(credit.titles.map((t) => t.year)).toEqual([2026, 1979, 1958]);
  });

  it('shows the trailers that were checked and none for the rest', async () => {
    const h = household();
    const detail = async (t: { mediaType: string; tmdbId: number }) =>
      titleDetail.parse(
        await h.json(h.adaKey, `/api/lumos/titles/${t.mediaType}/${t.tmdbId}`),
      );
    expect((await detail(PALM)).trailer).toMatchObject({
      provider: 'youtube',
      key: 'pI5w1I6IX40',
      publisher: 'Amazon Prime Video UK & IE',
    });
    expect(
      (await detail({ mediaType: 'movie', tmdbId: 9_000_003 })).trailer,
    ).toMatchObject({ provider: 'direct', license: 'CC BY 3.0' });
    expect((await detail(LOOP)).trailer).toBeNull();
    // A title without scores has none, not borrowed ones.
    expect((await detail(HOLDOVERS)).scores).toEqual([]);
  });

  it('is refused next to a real catalogue and on a deployed server', () => {
    const base = { BURROW_SECRET_KEY: 'x', LUMOS_CATALOGUE: 'fixture' };
    expect(loadConfig(base).lumosCatalogue).toBe('fixture');
    expect(() =>
      loadConfig({ ...base, LUMOS_SEERR_URL: 'http://seerr.example.com' }),
    ).toThrow(/local development only/);
    expect(() =>
      loadConfig({ ...base, BURROW_PUBLIC_URL: 'https://burrow.example.com' }),
    ).toThrow(/local development only/);
    expect(() =>
      loadConfig({
        ...base,
        CLOUDFLARE_ACCESS_TEAM: 'household.example.com',
        CLOUDFLARE_ACCESS_AUD: 'aud',
      }),
    ).toThrow(/local development only/);
    expect(loadConfig({ BURROW_SECRET_KEY: 'x' }).lumosCatalogue).toBe(
      undefined,
    );
  });
});

describe('lists', () => {
  it('keep one entry when both people add the same title to the shared list', async () => {
    const h = household();
    await h.add(h.adaKey, 'shared', PALM);
    await h.add(h.adaKey, 'shared', PALM);
    await h.add(h.bramKey, 'shared', PALM);
    const shared = await h.list(h.bramKey, 'shared');
    expect(ids(shared.items)).toEqual([9_000_001]);
    expect(shared.items[0]?.addedBy.name).toBe('Ada');
    expect((await h.row(h.bramKey, 'shared', 'list'))?.items[0]).toMatchObject({
      tmdbId: 9_000_001,
      onList: true,
      onShared: true,
    });
  });

  it('survive a server restart', async () => {
    const dbPath = join(mkdtempSync(join(tmpdir(), 'lumos-')), 'burrow.sqlite');
    const first = household({ dbPath });
    await first.add(first.adaKey, 'shared', HOLDOVERS);
    await first.add(first.adaKey, 'mine', SIGNAL_HILL);
    first.db.$client.close();

    const again = testHousehold({ dbPath });
    const key = again.key(first.ada.id, ['read']);
    const shared = listResponse.parse(
      await (await again.call(key, '/api/lumos/lists/shared')).json(),
    );
    const mine = listResponse.parse(
      await (await again.call(key, '/api/lumos/lists/mine')).json(),
    );
    expect(ids(shared.items)).toEqual([9_000_002]);
    expect(ids(mine.items)).toEqual([9_000_032]);
  });

  it('keep a personal list from the other person everywhere', async () => {
    const h = household();
    await h.add(h.adaKey, 'mine', LOOP);
    await h.verdict(h.adaKey, { scope: 'mine', ...PALM, kind: 'seen' });

    expect((await h.list(h.bramKey, 'mine')).items).toEqual([]);
    expect((await h.verdicts(h.bramKey, 'mine')).items).toEqual([]);
    const seenByBram = titleDetail.parse(
      await h.json(h.bramKey, '/api/lumos/titles/movie/9000019?scope=shared'),
    );
    expect(seenByBram).toMatchObject({ onMine: false, onShared: false });
    expect(
      (await h.rows(h.bramKey, 'shared')).rows.find(
        (r) => r.key === 'mine-not-shared',
      ),
    ).toBeUndefined();
    // Bram emptying his own list leaves hers alone.
    await h.send(
      h.bramKey,
      'DELETE',
      '/api/lumos/lists/mine/items/movie/9000019',
    );
    expect(ids((await h.list(h.adaKey, 'mine')).items)).toEqual([9_000_019]);
    // And her own "op jouw lijst, nog niet samen" row has it.
    expect(
      ids(
        ((await h.row(h.adaKey, 'shared', 'mine-not-shared'))?.items ?? []).map(
          (title) => ({ title }),
        ),
      ),
    ).toContain(9_000_019);
  });

  it('from the fixtures never request anything from the media server', async () => {
    const asked: unknown[] = [];
    const h = household({
      requester: {
        state: async (ref) => {
          asked.push(ref);
          return { known: false, requestId: null };
        },
        request: async (ref) => {
          asked.push(ref);
          return { requestId: 1, existed: false };
        },
      },
    });
    await h.add(h.adaKey, 'shared', HOLDOVERS);
    await h.add(h.adaKey, 'mine', SIGNAL_HILL);
    await h.lumos.requests?.run(new Date(Date.now() + 60_000));
    expect(h.lumos.requests).toBeUndefined();
    expect(asked).toEqual([]);
    expect(await h.json(h.adaKey, '/api/tasks')).toEqual([]);
  });

  it('from the fixtures never show up next to a real catalogue', async () => {
    const dbPath = join(mkdtempSync(join(tmpdir(), 'lumos-')), 'burrow.sqlite');
    const fixtures = household({ dbPath });
    await fixtures.add(fixtures.adaKey, 'shared', PALM);
    fixtures.db.$client.close();

    // The same titles, as if they came from the real catalogue.
    const titles = new FixtureCatalogue();
    const liveStandIn: CatalogueProvider = {
      origin: 'live',
      name: 'Seerr',
      candidates: () => titles.candidates(),
      title: (ref) => titles.title(ref),
      search: (q) => titles.search(q),
      browse: (q) => titles.browse(q),
      related: (ref) => titles.related(ref),
      person: (id) => titles.person(id),
    };
    const live = testHousehold({ dbPath, catalogue: liveStandIn });
    const key = live.key(fixtures.ada.id, ['read']);
    const shared = listResponse.parse(
      await (await live.call(key, '/api/lumos/lists/shared')).json(),
    );
    expect(shared.items).toEqual([]);
  });
});

describe('verdicts', () => {
  it('"niet nu" takes a title off the list and out of proposals, with its reason', async () => {
    const h = household();
    await h.add(h.adaKey, 'shared', PALM);
    await h.verdict(h.adaKey, {
      scope: 'shared',
      ...PALM,
      kind: 'not-now',
      reason: 'Liever een andere avond',
    });
    expect((await h.list(h.bramKey, 'shared')).items).toEqual([]);
    const tonight = await h.row(h.bramKey, 'shared', 'tonight');
    expect(tonight?.items.map((t) => t.tmdbId)).not.toContain(9_000_001);
    const passed = await h.verdicts(h.bramKey, 'shared');
    expect(passed.items).toMatchObject([
      {
        kind: 'not-now',
        reason: 'Liever een andere avond',
        by: { name: 'Ada' },
        title: { tmdbId: 9_000_001 },
      },
    ]);
    // Only for the household: Ada's own proposals still have it.
    expect(
      (await h.row(h.adaKey, 'mine', 'tonight'))?.items.map((t) => t.tmdbId),
    ).toContain(9_000_001);
    // Search ignores verdicts.
    const search = titleSearchResponse.parse(
      await h.json(h.adaKey, '/api/lumos/search?q=palm'),
    );
    expect(search.hits[0]?.title.pass).toMatchObject({ kind: 'not-now' });
  });

  it('"ja" clears an earlier "niet nu"', async () => {
    const h = household();
    await h.verdict(h.adaKey, { scope: 'shared', ...PALM, kind: 'not-now' });
    await h.add(h.bramKey, 'shared', PALM);
    expect((await h.verdicts(h.adaKey, 'shared')).items).toEqual([]);
  });

  it('"al gezien" hides a title without weighing similar titles down', async () => {
    const position = async (h: ReturnType<typeof household>) =>
      (await h.movies(h.adaKey, 'mine')).items.findIndex(
        (t) => t.tmdbId === LOOP.tmdbId,
      );
    const seen = household();
    const before = await position(seen);
    await seen.verdict(seen.adaKey, { scope: 'mine', ...PALM, kind: 'seen' });
    expect(await position(seen)).toBe(before);

    const less = household();
    await less.verdict(less.adaKey, {
      scope: 'mine',
      ...PALM,
      kind: 'less-like-this',
    });
    expect(await position(less)).toBeGreaterThan(before);
    const similar = titlesResponse.parse(
      await less.json(
        less.adaKey,
        '/api/lumos/similar/movie/9000019?scope=mine',
      ),
    );
    expect(similar.items.map((t) => t.tmdbId)).not.toContain(9_000_001);
  });
});

describe('undo', () => {
  const snapshot = async (h: ReturnType<typeof household>) => ({
    shared: await h.list(h.adaKey, 'shared'),
    mine: await h.list(h.adaKey, 'mine'),
    passedShared: await h.verdicts(h.adaKey, 'shared'),
    passedMine: await h.verdicts(h.adaKey, 'mine'),
  });

  it('restores the exact state before "niet nu" on a listed title', async () => {
    const h = household();
    await h.add(h.bramKey, 'shared', PALM);
    await h.verdict(h.adaKey, { scope: 'shared', ...PALM, kind: 'seen' });
    await h.add(h.adaKey, 'shared', PALM);
    await h.add(h.adaKey, 'mine', HOLDOVERS);
    const before = await snapshot(h);

    const changeId = await h.verdict(h.adaKey, {
      scope: 'shared',
      ...PALM,
      kind: 'not-now',
      reason: 'Niet ons ding',
    });
    expect(await snapshot(h)).not.toEqual(before);
    const res = await h.send(
      h.adaKey,
      'POST',
      `/api/lumos/changes/${changeId}/undo`,
    );
    expect(res.status).toBe(200);
    expect(await snapshot(h)).toEqual(before);
  });

  it('of "ja" brings back the "niet nu" it cleared', async () => {
    const h = household();
    await h.verdict(h.adaKey, {
      scope: 'mine',
      ...SIGNAL_HILL,
      kind: 'not-now',
      reason: 'Te spannend',
    });
    const before = await snapshot(h);
    const changeId = await h.add(h.adaKey, 'mine', SIGNAL_HILL);
    await h.send(h.adaKey, 'POST', `/api/lumos/changes/${changeId}/undo`);
    expect(await snapshot(h)).toEqual(before);
  });

  it('is only for whoever made the change, and only once', async () => {
    const h = household();
    const changeId = await h.add(h.adaKey, 'shared', PALM);
    const byBram = await h.send(
      h.bramKey,
      'POST',
      `/api/lumos/changes/${changeId}/undo`,
    );
    expect(byBram.status).toBe(404);
    const first = await h.send(
      h.adaKey,
      'POST',
      `/api/lumos/changes/${changeId}/undo`,
    );
    expect(first.status).toBe(200);
    const second = await h.send(
      h.adaKey,
      'POST',
      `/api/lumos/changes/${changeId}/undo`,
    );
    expect(second.status).toBe(404);
  });

  it('of a personal verdict is not open to the other person', async () => {
    const h = household();
    await h.verdict(h.adaKey, { scope: 'mine', ...PALM, kind: 'not-now' });
    const [mine] = (await h.verdicts(h.adaKey, 'mine')).items;
    const res = await h.send(
      h.bramKey,
      'DELETE',
      `/api/lumos/verdicts/${mine?.id}`,
    );
    expect(res.status).toBe(404);
    expect((await h.verdicts(h.adaKey, 'mine')).items).toHaveLength(1);
  });
});

describe('events', () => {
  it('tell both Macs about the shared list and only the owner about a personal one', async () => {
    const h = household();
    const seen: { personId: string; scope: unknown }[] = [];
    h.events.subscribe((e) => {
      if (e.data.type !== 'lumos.changed') return;
      for (const person of [h.ada, h.bram]) {
        const access = { personId: person.id } as never;
        if (e.visibleTo(access))
          seen.push({ personId: person.id, scope: e.data.scope });
      }
    });
    await h.add(h.adaKey, 'shared', PALM);
    await h.add(h.adaKey, 'mine', HOLDOVERS);
    expect(seen).toEqual([
      { personId: h.ada.id, scope: 'shared' },
      { personId: h.bram.id, scope: 'shared' },
      { personId: h.ada.id, scope: 'mine' },
    ]);
  });
});
describe('browsing and the Zoeker', () => {
  it('browses films the way a shop sorts them, by genre and decade, a page at a time', async () => {
    const h = household();
    const popular = browseResponse.parse(
      await h.json(h.adaKey, '/api/lumos/browse?type=movie&sort=popular'),
    );
    expect(popular.dataOrigin).toBe('fixture');
    expect(popular.items.length).toBeGreaterThan(5);
    expect(popular.items.every((t) => t.mediaType === 'movie')).toBe(true);
    expect(popular.genres.map((g) => g.name)).toContain('Komedie');
    const comedies = browseResponse.parse(
      await h.json(h.adaKey, '/api/lumos/browse?type=movie&genre=Komedie'),
    );
    expect(comedies.items.every((t) => t.genres.includes('Komedie'))).toBe(
      true,
    );
    const eighties = browseResponse.parse(
      await h.json(h.adaKey, '/api/lumos/browse?type=tv&decade=1980'),
    );
    expect(
      eighties.items.every(
        (t) => (t.year ?? 0) >= 1980 && (t.year ?? 0) < 1990,
      ),
    ).toBe(true);
    const page2 = browseResponse.parse(
      await h.json(h.adaKey, '/api/lumos/browse?type=movie&page=2'),
    );
    expect(page2.page).toBe(2);
    expect(page2.items.map((t) => t.tmdbId)).not.toEqual(
      popular.items.map((t) => t.tmdbId),
    );
    expect((await h.call(h.adaKey, '/api/lumos/browse?type=book')).status).toBe(
      400,
    );
  });

  it('shows a person with what they made, each title saying the part', async () => {
    const h = household();
    const found = titleSearchResponse.parse(
      await h.json(h.adaKey, '/api/lumos/search?q=samberg'),
    );
    const person = found.credits[0];
    expect(person?.name).toBe('Andy Samberg');
    const page = creditResponse.parse(
      await h.json(h.adaKey, `/api/lumos/credits/${person?.id}`),
    );
    expect(page.person?.name).toBe('Andy Samberg');
    expect(page.titles.map((t) => [t.title, t.match])).toContainEqual([
      'Palm Springs',
      'als zichzelf',
    ]);
    expect((await h.call(h.adaKey, '/api/lumos/credits/nobody')).status).toBe(
      404,
    );
  });

  it('builds the Zoeker from the list and the taste, leaves passed titles out, and reshuffles with the seed', async () => {
    const h = household();
    await h.add(h.adaKey, 'shared', { mediaType: 'movie', tmdbId: 9000001 });
    await h.verdict(h.adaKey, {
      scope: 'shared',
      mediaType: 'movie',
      tmdbId: 9000014,
      kind: 'not-now',
    });
    const one = rowsResponse.parse(
      await h.json(h.adaKey, '/api/lumos/explore?seed=1'),
    );
    const keys = one.rows.map((row) => row.key);
    expect(keys).toContain('like-movie:9000001');
    const likeRow = one.rows.find((row) => row.key === 'like-movie:9000001');
    expect(likeRow?.title).toBe('Als je Palm Springs goed vond');
    expect(
      likeRow?.items.every((t) => t.match === 'Lijkt op Palm Springs'),
    ).toBe(true);
    for (const row of one.rows) {
      expect(row.items.map((t) => t.tmdbId)).not.toContain(9000014);
    }
    const decadeOf = async (seed: number) =>
      rowsResponse
        .parse(await h.json(h.adaKey, `/api/lumos/explore?seed=${seed}`))
        .rows.find((row) => row.key.startsWith('decade-'))?.key;
    const decades = new Set(
      await Promise.all([1, 2, 3, 4, 5, 6, 7, 8].map(decadeOf)),
    );
    expect(decades.size).toBeGreaterThan(1);
    expect(await decadeOf(3)).toBe(await decadeOf(3));
  });
});
