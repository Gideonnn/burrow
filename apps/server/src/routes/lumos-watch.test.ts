import { lumosStatus, playResponse, watchResponse } from '@burrow/contracts';
import {
  type CatalogueProvider,
  type CatalogueTitle,
  JellyfinPlayer,
} from '@burrow/lumos';
import { describe, expect, it } from 'vitest';
import { loadConfig } from '../config';
import { testHousehold } from '../testing';

const KEY = 'jellyfin-service-key-1a2b3c4d5e6f';
const BASE = 'http://jellyfin.example.com:8096';
const WEB = 'http://media.example.nl:8096';

const title = (
  over: Partial<CatalogueTitle> &
    Pick<CatalogueTitle, 'mediaType' | 'tmdbId' | 'title'>,
): CatalogueTitle => ({
  year: 2024,
  runtimeMinutes: 100,
  seasons: null,
  genres: [],
  traits: [],
  language: 'en',
  poster: null,
  backdrop: null,
  availability: 'available',
  popularity: 1,
  synopsis: null,
  synopsisLanguage: null,
  credits: [],
  scores: [],
  snippets: [],
  trailer: null,
  stills: [],
  stillsCredit: null,
  tmdbUrl: null,
  ...over,
});

// The catalogue knows the film's Jellyfin id (Seerr passes it on); the
// series it only knows by name, and the third title is not in the library.
const film = title({
  mediaType: 'movie',
  tmdbId: 301,
  title: 'Harbour Lights',
  mediaServerId: 'jf-film-301',
});
const series = title({
  mediaType: 'tv',
  tmdbId: 402,
  title: 'Polder Blues',
  seasons: 2,
});
const missing = title({
  mediaType: 'movie',
  tmdbId: 303,
  title: 'Quiet Ferry',
  availability: 'not-requested',
});
const titles = [film, series, missing];

const catalogue: CatalogueProvider = {
  origin: 'live',
  name: 'Test',
  candidates: async () => titles,
  title: async (ref) =>
    titles.find(
      (t) => t.mediaType === ref.mediaType && t.tmdbId === ref.tmdbId,
    ),
  search: async () => ({ hits: [], credits: [] }),
  browse: async (q) => ({ page: q.page, totalPages: 1, items: [], genres: [] }),
  related: async () => [],
  person: async () => undefined,
};

// A stand-in for Jellyfin 12's API: a TV with the app open, a phone that
// cannot be controlled, and Lumos's own calls. Its answers carry the key
// and user records in places Lumos must never pass on.
function fakeJellyfin() {
  const calls: {
    method: string;
    path: string;
    query: string;
    token: string | null;
  }[] = [];
  const leak = {
    AccessToken: KEY,
    UserName: 'gideon-example',
    Password: 'hunter2',
  };
  const tv = {
    Id: 'sess-tv',
    UserId: 'user-1',
    Client: 'Jellyfin for WebOS',
    DeviceName: 'LG TV',
    DeviceId: 'webos-g4',
    SupportsRemoteControl: true,
    NowPlayingItem: undefined as { Id: string; Name: string } | undefined,
  };
  const phone = {
    Id: 'sess-phone',
    UserId: 'user-1',
    Client: 'Jellyfin Mobile',
    DeviceName: 'Phone',
    DeviceId: 'phone-1',
    SupportsRemoteControl: false,
  };
  const self = {
    Id: 'sess-self',
    Client: 'Burrow',
    DeviceName: 'Lumos',
    DeviceId: 'burrow-lumos',
    SupportsRemoteControl: true,
  };
  let down = false;
  let playsWhenTold = true;
  let watched = false;
  const fetch = async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const headers = new Headers(init?.headers);
    calls.push({
      method: init?.method ?? 'GET',
      path: url.pathname,
      query: url.search,
      token:
        headers.get('Authorization')?.match(/Token="([^"]+)"/)?.[1] ?? null,
    });
    if (down) throw new TypeError('fetch failed');
    if (url.origin !== BASE) return new Response('{}', { status: 404 });
    const path = url.pathname;
    if (path === '/System/Info/Public') {
      return Response.json({ Id: 'server-1', ServerName: 'Dobby' });
    }
    if (path === '/Items/jf-film-301') {
      return Response.json({
        Id: 'jf-film-301',
        Name: 'Harbour Lights',
        Type: 'Movie',
      });
    }
    if (path === '/Items') {
      const term = url.searchParams.get('searchTerm');
      return Response.json({
        Items:
          term === 'Polder Blues'
            ? [
                {
                  Id: 'jf-old',
                  Name: 'Polder Blues',
                  Type: 'Series',
                  ProviderIds: { Tmdb: '999' },
                },
                {
                  Id: 'jf-series-402',
                  Name: 'Polder Blues',
                  Type: 'Series',
                  ProviderIds: { Tmdb: '402', Tvdb: '77' },
                },
              ]
            : [],
      });
    }
    if (path === '/Sessions') {
      return Response.json([tv, phone, self].map((s) => ({ ...s, ...leak })));
    }
    if (path === '/Shows/NextUp') {
      return Response.json({
        Items: watched
          ? [
              {
                Id: 'jf-ep-2',
                Name: 'De dijk',
                IndexNumber: 2,
                ParentIndexNumber: 1,
              },
            ]
          : [],
      });
    }
    if (path === '/Shows/jf-series-402/Episodes') {
      return Response.json({
        Items: [
          {
            Id: 'jf-ep-1',
            Name: 'Pilot',
            IndexNumber: 1,
            ParentIndexNumber: 1,
          },
        ],
      });
    }
    if (path === '/Sessions/sess-tv/Playing' && init?.method === 'POST') {
      const id = url.searchParams.get('itemIds') ?? '';
      if (playsWhenTold) tv.NowPlayingItem = { Id: id, Name: `Playing ${id}` };
      return new Response(null, { status: 204 });
    }
    return new Response('{"message":"Not found"}', { status: 404 });
  };
  const player = new JellyfinPlayer({
    url: BASE,
    apiKey: KEY,
    webUrl: WEB,
    fetch: fetch as typeof globalThis.fetch,
    sleep: async () => {},
  });
  return {
    player,
    calls,
    setDown: (value: boolean) => {
      down = value;
    },
    setPlays: (value: boolean) => {
      playsWhenTold = value;
    },
    setWatched: (value: boolean) => {
      watched = value;
    },
  };
}

function household(withPlayer = true) {
  const fake = fakeJellyfin();
  const h = testHousehold({
    catalogue,
    player: withPlayer ? fake.player : undefined,
  });
  const ada = h.person('Ada');
  const key = h.key(ada.id, ['read', 'organize']);
  const reader = h.key(ada.id, ['read']);
  const watch = async (ref: string) =>
    watchResponse.parse(
      await (await h.call(key, `/api/lumos/watch/${ref}`)).json(),
    );
  const play = (ref: string, deviceId: string, as = key) =>
    h.call(as, `/api/lumos/watch/${ref}/screen`, {
      method: 'POST',
      body: JSON.stringify({ deviceId }),
    });
  return { ...h, ...fake, key, reader, watch, play };
}

describe('watching through Jellyfin', () => {
  it('says where a title can be watched: a page for this machine and the screens with Jellyfin open', async () => {
    const h = household();
    expect(
      lumosStatus.parse(await (await h.call(h.key, '/api/lumos/status')).json())
        .watch,
    ).toBe(true);
    expect(await h.watch('movie/301')).toEqual({
      web: `${WEB}/web/index.html#!/details?id=jf-film-301&serverId=server-1`,
      episode: null,
      screens: [
        {
          deviceId: 'webos-g4',
          name: 'LG TV',
          client: 'Jellyfin for WebOS',
          playing: null,
        },
      ],
    });
    // The id the catalogue knew was enough; no search by name.
    expect(h.calls.some((c) => c.path === '/Items/jf-film-301')).toBe(true);
    expect(h.calls.some((c) => c.path === '/Items')).toBe(false);
  });

  it('finds a series by its TMDB id among namesakes and names the episode a screen would start', async () => {
    const h = household();
    expect((await h.watch('tv/402')).episode).toEqual({
      season: 1,
      number: 1,
      title: 'Pilot',
    });
    h.setWatched(true);
    expect((await h.watch('tv/402')).episode).toEqual({
      season: 1,
      number: 2,
      title: 'De dijk',
    });
    expect((await h.watch('tv/402')).web).toContain('id=jf-series-402');
  });

  it('starts the title on the chosen screen and reports only what the screen confirms', async () => {
    const h = household();
    const started = playResponse.parse(
      await (await h.play('movie/301', 'webos-g4')).json(),
    );
    expect(started).toEqual({
      screen: {
        deviceId: 'webos-g4',
        name: 'LG TV',
        client: 'Jellyfin for WebOS',
        playing: 'Playing jf-film-301',
      },
      episode: null,
      confirmed: true,
    });
    const sent = h.calls.find((c) => c.method === 'POST');
    expect(sent?.path).toBe('/Sessions/sess-tv/Playing');
    expect(sent?.query).toBe('?playCommand=PlayNow&itemIds=jf-film-301');

    // A series starts at its episode.
    const episode = playResponse.parse(
      await (await h.play('tv/402', 'webos-g4')).json(),
    );
    expect(episode.episode).toEqual({ season: 1, number: 1, title: 'Pilot' });
    expect(h.calls.filter((c) => c.method === 'POST').at(-1)?.query).toBe(
      '?playCommand=PlayNow&itemIds=jf-ep-1',
    );

    // The screen that does not react is not called playing.
    h.setPlays(false);
    expect(
      playResponse.parse(await (await h.play('movie/301', 'webos-g4')).json())
        .confirmed,
    ).toBe(false);
  });

  it('refuses a screen without Jellyfin open, a title the library lacks, and a key that cannot organize', async () => {
    const h = household();
    expect((await h.play('movie/301', 'phone-1')).status).toBe(409);
    expect((await h.play('movie/301', 'webos-g4', h.reader)).status).toBe(403);
    expect(await h.watch('movie/303')).toMatchObject({
      web: null,
      episode: null,
    });
    expect((await h.play('movie/303', 'webos-g4')).status).toBe(400);
    expect((await h.call(h.key, '/api/lumos/watch/movie/999')).status).toBe(
      404,
    );
    expect(h.calls.filter((c) => c.method === 'POST')).toHaveLength(0);
  });

  it('never passes the key or Jellyfin user data on, and sends the key only to Jellyfin', async () => {
    const h = household();
    await h.play('movie/301', 'webos-g4');
    const answers = await Promise.all(
      [
        '/api/lumos/status',
        '/api/lumos/watch/movie/301',
        '/api/lumos/watch/tv/402',
      ].map(async (path) => (await h.call(h.key, path)).text()),
    );
    for (const text of answers) {
      expect(text).not.toContain(KEY);
      expect(text).not.toContain('hunter2');
      expect(text).not.toContain('gideon-example');
    }
    expect(h.calls.length).toBeGreaterThan(3);
    expect(h.calls.every((c) => c.token === KEY)).toBe(true);
  });

  it('answers 503 while Jellyfin is down, and without Jellyfin at all', async () => {
    const h = household();
    h.setDown(true);
    expect((await h.call(h.key, '/api/lumos/watch/movie/301')).status).toBe(
      503,
    );
    const none = household(false);
    expect(
      lumosStatus.parse(
        await (await none.call(none.key, '/api/lumos/status')).json(),
      ).watch,
    ).toBe(false);
    expect(
      (await none.call(none.key, '/api/lumos/watch/movie/301')).status,
    ).toBe(503);
  });

  it('is only used with both the address and the key', () => {
    const base = { BURROW_SECRET_KEY: 'k'.repeat(32) };
    expect(
      loadConfig({ ...base, LUMOS_JELLYFIN_URL: BASE }).jellyfin,
    ).toBeUndefined();
    expect(
      loadConfig({
        ...base,
        LUMOS_JELLYFIN_URL: BASE,
        LUMOS_JELLYFIN_API_KEY: ` ${KEY}\n`,
        LUMOS_JELLYFIN_WEB_URL: WEB,
      }).jellyfin,
    ).toEqual({ url: BASE, apiKey: KEY, webUrl: WEB });
  });
});
