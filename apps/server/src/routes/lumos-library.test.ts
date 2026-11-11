import {
  manageResponse,
  playResponse,
  rowsResponse,
  titleDetail,
  titleSearchResponse,
  verdictsResponse,
  watchResponse,
} from '@burrow/contracts';
import {
  bareTitle,
  type CatalogueProvider,
  type CatalogueTitle,
  type Holding,
  JellyfinPlayer,
  type MediaRequester,
  refKey,
  type TitleRef,
} from '@burrow/lumos';
import { describe, expect, it } from 'vitest';
import { loadConfig } from '../config';
import { testHousehold } from '../testing';

const KEY = 'jellyfin-service-key-9z8y7x6w5v4u';
const BASE = 'http://jellyfin.example.com:8096';
const GB = 1_000_000_000;
// Jellyfin counts time in ticks of 100 ns.
const TICKS = 10_000_000;

const title = (
  over: Partial<CatalogueTitle> &
    Pick<CatalogueTitle, 'mediaType' | 'tmdbId' | 'title'>,
): CatalogueTitle =>
  bareTitle({
    year: 2024,
    runtimeMinutes: 100,
    seasons: over.mediaType === 'tv' ? 1 : null,
    genres: ['Drama'],
    language: 'Engels',
    availability: 'available',
    popularity: 5,
    ...over,
  });

// On Dobby: two films seen together (one large, one small), one being
// watched, one copied in by hand, and a series half seen. Two titles are
// not there yet.
const titles = [
  title({ mediaType: 'movie', tmdbId: 501, title: 'Harbour Lights' }),
  title({ mediaType: 'movie', tmdbId: 502, title: 'Quiet Ferry' }),
  title({ mediaType: 'movie', tmdbId: 503, title: 'Low Tide' }),
  title({ mediaType: 'movie', tmdbId: 504, title: 'Already Home' }),
  title({ mediaType: 'tv', tmdbId: 601, title: 'Polder Blues' }),
  // Jellyfin has no TMDB id for this file; Seerr knows its item id.
  title({
    mediaType: 'movie',
    tmdbId: 507,
    title: 'Night Ferry',
    mediaServerId: 'JF-507',
  }),
  title({
    mediaType: 'movie',
    tmdbId: 505,
    title: 'Paper Town',
    availability: 'downloading',
  }),
  title({
    mediaType: 'movie',
    tmdbId: 506,
    title: 'Glass Harbour',
    availability: 'not-requested',
  }),
];
const added = '2026-09-01T10:00:00.000Z';
const handCopied = new Set(['movie:504']);

function fakeCatalogue(): CatalogueProvider {
  const held = (t: CatalogueTitle) =>
    t.availability === 'available'
      ? { ...t, addedAt: added, removable: !handCopied.has(refKey(t)) }
      : t;
  return {
    origin: 'live',
    name: 'Test',
    candidates: async () => titles.map(held),
    title: async (ref) => {
      const t = titles.find((x) => refKey(x) === refKey(ref));
      return t && held(t);
    },
    search: async () => ({
      hits: titles.map((t) => ({ title: held(t), why: null })),
      credits: [],
    }),
    browse: async (q) => ({
      page: q.page,
      totalPages: 1,
      items: titles.filter((t) => t.mediaType === q.mediaType).map(held),
      genres: [],
    }),
    related: async () => [],
    person: async () => undefined,
  };
}

// Seerr's side: what is on Dobby and what is coming.
function fakeRequester() {
  const library = new Set([
    'movie:501',
    'movie:502',
    'movie:503',
    'movie:504',
    'movie:507',
    'tv:601',
  ]);
  const removed: string[] = [];
  const requester: MediaRequester = {
    state: async () => ({ known: true, requestId: null }),
    request: async () => ({ requestId: null, existed: true }),
    holdings: async () => {
      const holding = (t: CatalogueTitle): Holding => ({
        title: t,
        download: null,
        addedAt: added,
        removable: !handCopied.has(refKey(t)),
      });
      return {
        busy: [
          {
            title: titles.find((t) => t.tmdbId === 505) as CatalogueTitle,
            download: {
              progress: 0.5,
              eta: '2026-11-10T22:00:00Z',
              bytesLeft: 5 * GB,
            },
            addedAt: null,
            removable: true,
          },
        ],
        library: titles.filter((t) => library.has(refKey(t))).map(holding),
      };
    },
    remove: async (ref: TitleRef) => {
      library.delete(refKey(ref));
      removed.push(refKey(ref));
    },
  };
  return { requester, removed };
}

const stream = (
  Type: string,
  more: Record<string, unknown> = {},
): Record<string, unknown> => ({ Type, ...more });

// A stand-in for Jellyfin 12's API with the household's one account. Its
// answers carry user records Lumos must never pass on.
function fakeJellyfin(user?: string) {
  const calls: { method: string; path: string; query: URLSearchParams }[] = [];
  const leak = { Policy: { IsAdministrator: true }, Password: 'hunter2' };
  const users = [
    { Id: 'u-house', Name: 'Woonkamer', ...leak },
    { Id: 'u-guest', Name: 'Gast', ...leak },
  ];
  const data = (over: Record<string, unknown> = {}) => ({
    Played: false,
    PlayCount: 0,
    PlaybackPositionTicks: 0,
    ...over,
  });
  const film = (
    id: string,
    tmdb: number,
    name: string,
    size: number,
    userData: Record<string, unknown>,
    streams: Record<string, unknown>[],
  ) => ({
    Id: id,
    Name: name,
    Type: 'Movie',
    ProviderIds: { Tmdb: String(tmdb), Imdb: 'tt0000001' },
    RunTimeTicks: 6000 * TICKS,
    MediaSources: [{ Id: `src-${id}`, Size: size, MediaStreams: streams }],
    UserData: data(userData),
  });
  const library = [
    film(
      'jf-501',
      501,
      'Harbour Lights',
      30 * GB,
      { Played: true, PlayCount: 2, LastPlayedDate: '2026-10-30T21:00:00Z' },
      [
        stream('Video', { Width: 3840, Height: 2160, VideoRangeType: 'HDR10' }),
        stream('Audio', { Language: 'eng' }),
        stream('Audio', { Language: 'dut' }),
        stream('Subtitle', { Language: 'dut' }),
        stream('Subtitle', { Language: 'eng' }),
        stream('Subtitle', { Language: 'eng' }),
      ],
    ),
    film(
      'jf-502',
      502,
      'Quiet Ferry',
      8 * GB,
      { PlaybackPositionTicks: 3000 * TICKS, PlayedPercentage: 50 },
      [
        stream('Video', { Width: 1920, Height: 1080, VideoRangeType: 'SDR' }),
        stream('Audio', { Language: 'nld' }),
      ],
    ),
    film('jf-503', 503, 'Low Tide', 40 * GB, { Played: true, PlayCount: 1 }, [
      stream('Video', { Width: 3840, Height: 1600, VideoRangeType: 'DOVI' }),
    ]),
    film('jf-504', 504, 'Already Home', 50 * GB, { Played: true }, []),
    {
      ...film(
        'jf-507',
        0,
        'Night Ferry',
        12 * GB,
        { PlaybackPositionTicks: 1200 * TICKS },
        [stream('Video', { Width: 1280, Height: 720 })],
      ),
      ProviderIds: { Imdb: 'tt0000002' },
    },
    {
      Id: 'jf-601',
      Name: 'Polder Blues',
      Type: 'Series',
      ProviderIds: { Tmdb: '601' },
      RecursiveItemCount: 4,
      UserData: data({ UnplayedItemCount: 1 }),
    },
  ];
  const episodes = [1, 2, 3, 4].map((n) => ({
    Id: `jf-ep-60${n}`,
    Name: `Aflevering ${n}`,
    Type: 'Episode',
    SeriesId: 'jf-601',
    IndexNumber: n,
    ParentIndexNumber: 1,
    RunTimeTicks: 3000 * TICKS,
    MediaSources: [
      {
        Size: 2 * GB,
        MediaStreams: [
          stream('Video', { Width: 1920, Height: 1080 }),
          stream('Audio', { Language: 'dut' }),
        ],
      },
    ],
    UserData: data(n < 4 ? { Played: true, PlayCount: 1 } : {}),
  }));
  const nextUp = {
    ...episodes[3],
    UserData: data({ PlaybackPositionTicks: 600 * TICKS }),
  };
  const tv = {
    Id: 'sess-tv',
    UserId: 'u-house',
    Client: 'Jellyfin for WebOS',
    DeviceName: 'LG TV',
    DeviceId: 'webos-g4',
    SupportsRemoteControl: true,
    NowPlayingItem: undefined as { Id: string; Name: string } | undefined,
  };
  // Without the user's id the answers carry no user data, as Jellyfin does.
  const forUser = <T extends { UserData?: unknown }>(
    items: T[],
    q: URLSearchParams,
  ) =>
    q.get('userId') === 'u-house'
      ? items
      : items.map(({ UserData: _u, ...rest }) => rest);
  const fetch = async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const q = url.searchParams;
    calls.push({ method: init?.method ?? 'GET', path: url.pathname, query: q });
    if (url.origin !== BASE) return new Response('{}', { status: 404 });
    const path = url.pathname;
    if (path.startsWith('/Items/') && !q.has('userId')) {
      return new Response('Error processing request.', { status: 400 });
    }
    if (path === '/Users') return Response.json(users);
    if (path === '/System/Info/Public')
      return Response.json({ Id: 'server-1' });
    if (path === '/System/Info/Storage') {
      const folder = (Path: string) => ({
        Path,
        FreeSpace: 400 * GB,
        UsedSpace: 600 * GB,
        StorageType: 'ext4',
        DeviceId: 'dev-1',
      });
      return Response.json({
        ProgramDataFolder: {
          ...folder('/var/lib/jellyfin'),
          DeviceId: 'dev-0',
          FreeSpace: 1,
        },
        Libraries: [
          { Id: 'lib-1', Name: 'Films', Folders: [folder('/srv/media/films')] },
          {
            Id: 'lib-2',
            Name: 'Series',
            Folders: [folder('/srv/media/series')],
          },
        ],
      });
    }
    if (path === '/Items') {
      const types = q.get('includeItemTypes') ?? '';
      const ids = q.get('ids')?.split(',');
      let items: Record<string, unknown>[] = [];
      if (ids)
        items = [...library, ...episodes].filter((i) =>
          ids.includes(String(i.Id)),
        );
      else if (types === 'Episode') items = episodes;
      else if (types.includes('Movie') && types.includes('Series'))
        items = library;
      else if (q.get('searchTerm')) {
        items = library.filter((i) => i.Name === q.get('searchTerm'));
      }
      return Response.json({
        Items: forUser(items, q),
        TotalRecordCount: items.length,
      });
    }
    if (path === '/UserItems/Resume') {
      return Response.json({
        Items: q.get('userId') === 'u-house' ? [library[1], library[4]] : [],
      });
    }
    if (path === '/Shows/NextUp') {
      return Response.json({
        Items: q.get('userId') === 'u-house' ? [nextUp] : [],
      });
    }
    if (path === '/Shows/jf-601/Episodes') {
      return Response.json({ Items: forUser(episodes, q) });
    }
    if (path === '/Sessions') return Response.json([tv]);
    if (path === '/Sessions/sess-tv/Playing' && init?.method === 'POST') {
      const id = q.get('itemIds') ?? '';
      tv.NowPlayingItem = { Id: id, Name: id };
      return new Response(null, { status: 204 });
    }
    return new Response('{"message":"Not found"}', { status: 404 });
  };
  const player = new JellyfinPlayer({
    url: BASE,
    apiKey: KEY,
    user,
    fetch: fetch as typeof globalThis.fetch,
    sleep: async () => {},
  });
  return { player, calls };
}

function household(user: string | null = 'woonkamer') {
  const jellyfin = fakeJellyfin(user ?? undefined);
  const seerr = fakeRequester();
  const h = testHousehold({
    catalogue: fakeCatalogue(),
    requester: seerr.requester,
    player: jellyfin.player,
  });
  const ada = h.person('Ada');
  const bram = h.person('Bram');
  const adaKey = h.key(ada.id, ['read', 'organize']);
  const bramKey = h.key(bram.id, ['read', 'organize']);
  const admin = h.key(ada.id, ['read', 'organize', 'admin']);
  const get = async (key: string, path: string) =>
    (await h.call(key, path)).json();
  const manage = async (key = adaKey) =>
    manageResponse.parse(await get(key, '/api/lumos/manage'));
  const put = (key: string, scope: string, ref: string) =>
    h.call(key, `/api/lumos/lists/${scope}/items/${ref}`, {
      method: 'PUT',
      body: '{}',
    });
  const item = async (ref: string, key = adaKey) =>
    (await manage(key)).library.find(
      (i) => `${i.title.mediaType}/${i.title.tmdbId}` === ref,
    );
  return {
    ...h,
    ...jellyfin,
    ...seerr,
    ada,
    bram,
    adaKey,
    bramKey,
    admin,
    get,
    manage,
    put,
    item,
  };
}

describe('Bibliotheek with what Jellyfin knows', () => {
  it('shows size, media facts and what the household account has seen, and the disk once per device', async () => {
    const h = household();
    const page = await h.manage();
    expect(page.disk).toEqual({ totalBytes: 1000 * GB, freeBytes: 400 * GB });
    const film = page.library.find((i) => i.title.tmdbId === 501);
    expect(film?.server).toEqual({
      sizeBytes: 30 * GB,
      media: {
        resolution: '4K',
        hdr: 'HDR10',
        audio: ['Engels', 'Nederlands'],
        subtitles: ['Nederlands', 'Engels'],
      },
      watched: {
        played: true,
        playCount: 2,
        lastPlayed: '2026-10-30T21:00:00Z',
        episodesPlayed: null,
        episodes: null,
        resume: null,
      },
    });
    expect((await h.item('movie/503'))?.server?.media?.hdr).toBe(
      'Dolby Vision',
    );
    // Found by the id Seerr knows, though Jellyfin has no TMDB id for it.
    expect((await h.item('movie/507'))?.server).toMatchObject({
      sizeBytes: 12 * GB,
      media: { resolution: '720p' },
    });
    const series = await h.item('tv/601');
    expect(series?.server?.sizeBytes).toBe(8 * GB);
    expect(series?.server?.media?.resolution).toBe('1080p');
    expect(series?.server?.watched).toMatchObject({
      played: false,
      episodesPlayed: 3,
      episodes: 4,
      resume: {
        positionSeconds: 600,
        runtimeSeconds: 3000,
        episode: { season: 1, number: 4, title: 'Aflevering 4' },
      },
    });
    expect(page.busy[0]?.download).toEqual({
      progress: 0.5,
      eta: '2026-11-10T22:00:00Z',
      bytesLeft: 5 * GB,
    });
  });

  it('asks Jellyfin for the whole library in a few calls, however many titles there are', async () => {
    const h = household();
    await h.manage();
    await h.manage();
    const items = h.calls.filter((c) => c.path === '/Items');
    expect(items.length).toBeLessThanOrEqual(2);
    expect(h.calls.filter((c) => c.path.startsWith('/Items/'))).toEqual([]);
  });

  it('proposes to make room with what was seen together, is large and is on nobody list', async () => {
    const h = household();
    // Low Tide is on Bram's own list; Already Home was copied in by hand.
    await h.put(h.bramKey, 'mine', 'movie/503');
    const page = await h.manage();
    const candidates = page.library
      .filter((i) => i.spaceCandidate)
      .map((i) => i.title.title);
    expect(candidates).toEqual(['Harbour Lights']);
    // Ada learns nothing of Bram's list beyond this one flag.
    expect(JSON.stringify(page)).not.toContain(h.bram.id);
  });

  it('records a shared Al gezien when deleting a watched title, and leaves an unwatched one and the lists alone', async () => {
    const h = household();
    await h.put(h.adaKey, 'shared', 'movie/501');
    expect(
      (
        await h.call(h.admin, '/api/lumos/library/movie/501', {
          method: 'DELETE',
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await h.call(h.admin, '/api/lumos/library/movie/502', {
          method: 'DELETE',
        })
      ).status,
    ).toBe(200);
    expect(h.removed).toEqual(['movie:501', 'movie:502']);
    const verdicts = verdictsResponse.parse(
      await h.get(h.adaKey, '/api/lumos/verdicts?scope=shared'),
    );
    expect(verdicts.items.map((v) => [v.title.tmdbId, v.kind])).toEqual([
      [501, 'seen'],
    ]);
    const film = titleDetail.parse(
      await h.get(h.adaKey, '/api/lumos/titles/movie/501'),
    );
    expect(film.onList).toBe(true);
  });

  it('also records it when only Lumos knows the title was seen', async () => {
    const h = household(null);
    await h.call(h.bramKey, '/api/lumos/verdicts', {
      method: 'POST',
      body: JSON.stringify({
        scope: 'mine',
        mediaType: 'movie',
        tmdbId: 502,
        kind: 'seen',
      }),
    });
    await h.call(h.admin, '/api/lumos/library/movie/502', { method: 'DELETE' });
    const verdicts = verdictsResponse.parse(
      await h.get(h.adaKey, '/api/lumos/verdicts?scope=shared'),
    );
    expect(verdicts.items.map((v) => [v.title.tmdbId, v.kind])).toEqual([
      [502, 'seen'],
    ]);
  });

  it('shows Op Dobby on the title page, with Lumos seen per person', async () => {
    const h = household();
    await h.call(h.adaKey, '/api/lumos/verdicts', {
      method: 'POST',
      body: JSON.stringify({
        scope: 'mine',
        mediaType: 'movie',
        tmdbId: 501,
        kind: 'seen',
      }),
    });
    const film = titleDetail.parse(
      await h.get(h.adaKey, '/api/lumos/titles/movie/501'),
    );
    expect(film.library).toMatchObject({
      addedAt: added,
      removable: true,
      server: { sizeBytes: 30 * GB, watched: { played: true } },
    });
    expect(film.seen).toEqual({ together: false, me: true });
    const bram = titleDetail.parse(
      await h.get(h.bramKey, '/api/lumos/titles/movie/501'),
    );
    expect(bram.seen).toEqual({ together: false, me: false });
    const away = titleDetail.parse(
      await h.get(h.adaKey, '/api/lumos/titles/movie/506'),
    );
    expect(away.library).toBeNull();
  });
});

describe('Ontdekken with what the household watched', () => {
  it('starts with Verder kijken, and hides what was seen together from the proposals but not from search', async () => {
    const h = household();
    const rows = rowsResponse.parse(await h.get(h.adaKey, '/api/lumos/rows'));
    expect(rows.rows[0]?.key).toBe('continue');
    expect(rows.rows[0]?.title).toBe('Verder kijken');
    expect(rows.rows[0]?.items.map((t) => [t.title, t.match])).toEqual([
      ['Quiet Ferry', 'Nog 50 min'],
      ['Night Ferry', 'Nog 80 min'],
      ['Polder Blues', 'S1E4 Aflevering 4, nog 40 min'],
    ]);
    const tonight = rows.rows.find((r) => r.key === 'tonight');
    const proposed = tonight?.items.map((t) => t.title) ?? [];
    expect(proposed).not.toContain('Harbour Lights');
    expect(proposed).toContain('Glass Harbour');
    const found = titleSearchResponse.parse(
      await h.get(h.adaKey, '/api/lumos/search?q=harbour'),
    );
    expect(found.hits.map((x) => x.title.title)).toContain('Harbour Lights');
  });

  it('narrows the rows to films or series', async () => {
    const h = household();
    const rows = rowsResponse.parse(
      await h.get(h.adaKey, '/api/lumos/rows?type=tv'),
    );
    const kinds = new Set(
      rows.rows.flatMap((r) => r.items.map((t) => t.mediaType)),
    );
    expect([...kinds]).toEqual(['tv']);
  });

  it('K picks up where the household stopped, a film at its position and a series at its episode', async () => {
    const h = household();
    const watch = watchResponse.parse(
      await h.get(h.adaKey, '/api/lumos/watch/movie/502'),
    );
    expect(watch.resume).toEqual({
      positionSeconds: 3000,
      runtimeSeconds: 6000,
      episode: null,
    });
    const play = (ref: string) =>
      h.call(h.adaKey, `/api/lumos/watch/${ref}/screen`, {
        method: 'POST',
        body: JSON.stringify({ deviceId: 'webos-g4' }),
      });
    const film = playResponse.parse(await (await play('movie/502')).json());
    expect(film.startSeconds).toBe(3000);
    const sent = () => h.calls.filter((c) => c.method === 'POST').at(-1)?.query;
    expect(sent()?.get('itemIds')).toBe('jf-502');
    expect(sent()?.get('startPositionTicks')).toBe(String(3000 * TICKS));
    const series = playResponse.parse(await (await play('tv/601')).json());
    expect(series.episode).toEqual({
      season: 1,
      number: 4,
      title: 'Aflevering 4',
    });
    expect(sent()?.get('itemIds')).toBe('jf-ep-604');
    expect(sent()?.get('startPositionTicks')).toBe(String(600 * TICKS));
    // A title seen to the end starts from the beginning.
    await play('movie/501');
    expect(sent()?.has('startPositionTicks')).toBe(false);
  });
});

describe('reading Jellyfin as the household account', () => {
  it('only reads: the one write is telling a screen to play', async () => {
    const h = household();
    await h.manage();
    await h.get(h.adaKey, '/api/lumos/rows');
    await h.get(h.adaKey, '/api/lumos/titles/tv/601');
    await h.call(h.adaKey, '/api/lumos/watch/movie/502/screen', {
      method: 'POST',
      body: JSON.stringify({ deviceId: 'webos-g4' }),
    });
    const writes = h.calls.filter((c) => c.method !== 'GET');
    expect(writes.map((c) => c.path)).toEqual(['/Sessions/sess-tv/Playing']);
    expect(
      h.calls
        .filter((c) => c.query.has('userId'))
        .every((c) => c.query.get('userId') === 'u-house'),
    ).toBe(true);
    const text = JSON.stringify(await h.manage());
    expect(text).not.toContain('hunter2');
    expect(text).not.toContain('u-house');
  });

  it('without a configured account shows sizes and facts but no watched state, and never picks a user', async () => {
    const h = household(null);
    const film = await h.item('movie/501');
    expect(film?.server?.sizeBytes).toBe(30 * GB);
    expect(film?.server?.watched).toBeNull();
    expect(film?.spaceCandidate).toBe(false);
    const rows = rowsResponse.parse(await h.get(h.adaKey, '/api/lumos/rows'));
    expect(rows.rows.map((r) => r.key)).not.toContain('continue');
    expect(
      h.calls.some((c) => c.path === '/Users' || c.query.has('userId')),
    ).toBe(false);
  });

  it('finds the account by name or id and never guesses another', async () => {
    const byId = household('u-house');
    expect((await byId.item('movie/501'))?.server?.watched?.played).toBe(true);
    const unknown = household('nobody');
    expect((await unknown.item('movie/501'))?.server?.watched).toBeNull();
    expect(unknown.calls.some((c) => c.query.has('userId'))).toBe(false);
  });

  it('takes the account from LUMOS_JELLYFIN_USER', () => {
    const config = loadConfig({
      BURROW_SECRET_KEY: 'k'.repeat(32),
      LUMOS_JELLYFIN_URL: BASE,
      LUMOS_JELLYFIN_API_KEY: KEY,
      LUMOS_JELLYFIN_USER: ' Woonkamer ',
    });
    expect(config.jellyfin).toEqual({
      url: BASE,
      apiKey: KEY,
      webUrl: undefined,
      user: 'Woonkamer',
    });
  });
});

describe('Op Dobby without a media server', () => {
  it('claims nothing about files when Seerr is not connected', async () => {
    const h = testHousehold();
    const key = h.key(h.person('Ada').id, ['read']);
    const film = titleDetail.parse(
      await (await h.call(key, '/api/lumos/titles/movie/9000001')).json(),
    );
    expect(film.availability).toBe('available');
    expect(film.library).toBeNull();
  });
});
