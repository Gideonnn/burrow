import {
  listResponse,
  rowsResponse,
  titleDetail,
  titleSearchResponse,
} from '@burrow/contracts';
import { REQUEST_GRACE_MS, SeerrCatalogue } from '@burrow/lumos';
import { describe, expect, it } from 'vitest';
import { loadConfig } from '../config';
import { testHousehold } from '../testing';

const KEY = 'seerr-service-key-0f9e8d7c6b5a';
const BASE = 'http://seerr.example.com:5055';

type Media = { status: number; requests?: { id: number }[] };

// A stand-in for Seerr's API with the shapes of version 3.5.1. Its answers
// carry the key and user records in places Lumos must never pass on.
function fakeSeerr() {
  const media = new Map<string, Media>();
  const calls: { method: string; path: string; key: string | null }[] = [];
  const posted: unknown[] = [];
  let down = false;
  let nextRequest = 500;
  const leak = { apiKey: KEY, email: 'ops@example.com', plexToken: KEY };
  const info = (type: string, id: number) => {
    const m = media.get(`${type}:${id}`);
    return m
      ? {
          ...m,
          requests: (m.requests ?? []).map((r) => ({
            ...r,
            requestedBy: leak,
          })),
        }
      : undefined;
  };
  const movie = (id: number, title: string, date: string) => ({
    id,
    mediaType: 'movie',
    title,
    releaseDate: date,
    posterPath: `/p${id}.jpg`,
    backdropPath: `/b${id}.jpg`,
    overview: `${title}, an invented test film.`,
    popularity: 120,
    voteAverage: 7.46,
    voteCount: 2100,
    genreIds: [35],
    originalLanguage: 'en',
    mediaInfo: info('movie', id),
  });
  const series = (id: number, name: string) => ({
    id,
    mediaType: 'tv',
    name,
    firstAirDate: '2025-02-01',
    posterPath: `/p${id}.jpg`,
    backdropPath: null,
    overview: `${name}, an invented test series.`,
    voteAverage: 8.1,
    voteCount: 300,
    genreIds: [18],
    originalLanguage: 'nl',
    mediaInfo: info('tv', id),
  });
  const routes: Record<string, (q: URLSearchParams) => unknown> = {
    '/genres/movie': () => [{ id: 35, name: 'Comedy' }],
    '/genres/tv': () => [{ id: 18, name: 'Drama' }],
    '/discover/trending': (q) =>
      q.get('page') === '1'
        ? {
            results: [
              movie(101, 'Harbour Lights', '2026-03-01'),
              series(202, 'Polder Blues'),
            ],
          }
        : { results: [] },
    '/discover/movies': () => ({
      results: [movie(103, 'Quiet Ferry', '1979-05-02')],
    }),
    '/discover/tv': () => ({ results: [] }),
    '/media': () => ({
      results: [{ mediaType: 'movie', tmdbId: 104, status: 5, settings: leak }],
    }),
    '/movie/101': () => ({
      ...movie(101, 'Harbour Lights', '2026-03-01'),
      runtime: 104,
      genres: [{ id: 35, name: 'Comedy' }],
      keywords: [{ id: 1, name: 'harbour' }],
      relatedVideos: [
        { site: 'YouTube', type: 'Featurette', key: 'feat0000001' },
        { site: 'YouTube', type: 'Trailer', key: 'trail000001', url: 'x' },
      ],
      credits: {
        cast: [{ id: 7, name: 'Lotte Example', order: 0 }],
        crew: [{ id: 8, name: 'Joris Example', job: 'Director' }],
      },
      externalIds: { imdbId: 'tt0000001' },
      mediaInfo: { ...info('movie', 101), downloadStatus: undefined },
    }),
    '/movie/101/ratingscombined': () => ({
      rt: {
        url: 'https://www.rottentomatoes.com/m/x',
        criticsScore: 91,
        audienceScore: 84,
      },
      imdb: { url: 'https://www.imdb.com/title/tt0000001', criticsScore: 7.2 },
    }),
    '/movie/104': () => ({
      ...movie(104, 'Already Home', '2019-01-01'),
      mediaInfo: { status: 5, requests: [{ id: 9, requestedBy: leak }] },
    }),
    '/tv/202': () => ({
      ...series(202, 'Polder Blues'),
      numberOfSeasons: 3,
      createdBy: [{ id: 9, name: 'Ilse Example' }],
    }),
    '/search': () => ({
      results: [
        movie(103, 'Quiet Ferry', '1979-05-02'),
        {
          id: 7,
          mediaType: 'person',
          name: 'Lotte Example',
          knownFor: [movie(101, 'Harbour Lights', '2026-03-01')],
        },
      ],
    }),
  };
  const fetch = async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const path = url.pathname.replace(/^\/api\/v1/, '');
    const headers = new Headers(init?.headers);
    calls.push({
      method: init?.method ?? 'GET',
      path,
      key: headers.get('X-Api-Key'),
    });
    if (down) throw new TypeError('fetch failed');
    if (url.origin !== BASE) return new Response('{}', { status: 404 });
    if (init?.method === 'POST' && path === '/request') {
      const body = JSON.parse(String(init.body));
      posted.push(body);
      const id = nextRequest++;
      media.set(`${body.mediaType}:${body.mediaId}`, {
        status: 2,
        requests: [{ id }],
      });
      return Response.json(
        { id, status: 2, requestedBy: leak },
        { status: 201 },
      );
    }
    const route = routes[path];
    if (!route) return new Response('{"message":"Not found"}', { status: 404 });
    return Response.json(route(url.searchParams));
  };
  const seerr = new SeerrCatalogue({
    url: BASE,
    apiKey: KEY,
    fetch: fetch as typeof globalThis.fetch,
  });
  return {
    seerr,
    calls,
    posted,
    media,
    setDown: (value: boolean) => {
      down = value;
    },
  };
}

function household() {
  const fake = fakeSeerr();
  const h = testHousehold({ catalogue: fake.seerr, requester: fake.seerr });
  const ada = h.person('Ada');
  const bram = h.person('Bram');
  const adaKey = h.key(ada.id, ['read', 'organize']);
  const bramKey = h.key(bram.id, ['read', 'organize']);
  const json = async (key: string, path: string) =>
    (await h.call(key, path)).json();
  const put = (key: string, scope: string, ref: string, body: unknown = {}) =>
    h.call(key, `/api/lumos/lists/${scope}/items/${ref}`, {
      method: 'PUT',
      body: JSON.stringify(body),
    });
  const detail = async (ref: string) =>
    titleDetail.parse(await json(adaKey, `/api/lumos/titles/${ref}`));
  // As if the grace period had passed.
  const later = (ms = REQUEST_GRACE_MS + 1_000) =>
    h.lumos.requests?.run(new Date(Date.now() + ms));
  return {
    ...h,
    ...fake,
    ada,
    bram,
    adaKey,
    bramKey,
    json,
    put,
    detail,
    later,
  };
}

describe('the live catalogue from Seerr', () => {
  it('shows real metadata, artwork, trailers and scores per source', async () => {
    const h = household();
    expect(await h.json(h.adaKey, '/api/lumos/status')).toEqual({
      dataOrigin: 'live',
      catalogue: 'Seerr',
      requests: true,
    });
    const rows = rowsResponse.parse(await h.json(h.adaKey, '/api/lumos/rows'));
    expect(rows.dataOrigin).toBe('live');
    const first = rows.rows[0]?.items.find((t) => t.tmdbId === 101);
    expect(first).toMatchObject({
      title: 'Harbour Lights',
      year: 2026,
      genres: ['Comedy'],
      poster: 'https://image.tmdb.org/t/p/w342/p101.jpg',
      availability: 'not-requested',
    });
    const available = rows.rows.find((r) => r.key === 'available');
    expect(available?.items.map((t) => t.tmdbId)).toEqual([104]);

    const film = await h.detail('movie/101');
    expect(film.trailer).toMatchObject({
      provider: 'youtube',
      key: 'trail000001',
    });
    expect(film.credits).toEqual([
      { id: '8', name: 'Joris Example', role: 'director' },
      { id: '7', name: 'Lotte Example', role: 'cast' },
    ]);
    expect(
      film.scores.map((s) => [s.source, s.label, s.value, s.votes]),
    ).toEqual([
      ['IMDb', null, 7.2, null],
      ['Rotten Tomatoes', 'Critics', 91, null],
      ['Rotten Tomatoes', 'Audience', 84, null],
      ['TMDB', null, 7.5, 2100],
    ]);
    expect(film.runtimeMinutes).toBe(104);
    expect(film.synopsisLanguage).toBe('en');
    expect((await h.detail('tv/202')).seasons).toBe(3);
  });

  it('finds titles by name and through a person, old and new alike', async () => {
    const h = household();
    const found = titleSearchResponse.parse(
      await h.json(h.adaKey, '/api/lumos/search?q=example'),
    );
    expect(found.hits.map((hit) => [hit.title.tmdbId, hit.why])).toEqual([
      [103, null],
      [101, 'Werk van Lotte Example'],
    ]);
    expect(found.hits[0]?.title.year).toBe(1979);
    expect(found.credits).toEqual([{ id: '7', name: 'Lotte Example' }]);
  });

  it('never passes the key or Seerr user data on, and sends the key only to Seerr', async () => {
    const h = household();
    await h.put(h.adaKey, 'shared', 'movie/101');
    await h.later();
    const answers = await Promise.all(
      [
        '/api/lumos/status',
        '/api/lumos/rows',
        '/api/lumos/titles',
        '/api/lumos/search?q=example',
        '/api/lumos/titles/movie/101',
        '/api/lumos/titles/movie/104',
        '/api/lumos/lists/shared',
      ].map(async (path) => (await h.call(h.adaKey, path)).text()),
    );
    for (const text of answers) {
      expect(text).not.toContain(KEY);
      expect(text).not.toContain('ops@example.com');
    }
    expect(h.calls.length).toBeGreaterThan(5);
    expect(h.calls.every((c) => c.key === KEY)).toBe(true);
  });

  it('is only used with both the address and the key, and rules out the fixtures', () => {
    const base = { BURROW_SECRET_KEY: 'k'.repeat(32) };
    expect(
      loadConfig({ ...base, LUMOS_SEERR_URL: BASE }).seerr,
    ).toBeUndefined();
    expect(
      loadConfig({
        ...base,
        LUMOS_SEERR_URL: BASE,
        LUMOS_SEERR_API_KEY: ` ${KEY}\n`,
      }).seerr,
    ).toEqual({ url: BASE, apiKey: KEY });
    expect(() =>
      loadConfig({
        ...base,
        LUMOS_SEERR_URL: BASE,
        LUMOS_SEERR_API_KEY: KEY,
        LUMOS_CATALOGUE: 'fixture',
      }),
    ).toThrow(/local development only/);
  });
});

describe('a title on a list', () => {
  it('is requested from Seerr once, after the undo window, however often it is added', async () => {
    const h = household();
    expect((await h.put(h.adaKey, 'shared', 'movie/101')).status).toBe(200);
    expect((await h.put(h.bramKey, 'shared', 'movie/101')).status).toBe(200);
    expect((await h.put(h.adaKey, 'mine', 'movie/101')).status).toBe(200);

    await h.lumos.requests?.run();
    expect(h.posted).toEqual([]);
    expect((await h.detail('movie/101')).request?.status).toBe('pending');

    await h.later();
    await h.later(REQUEST_GRACE_MS * 10);
    expect(h.posted).toEqual([{ mediaType: 'movie', mediaId: 101 }]);
    const film = await h.detail('movie/101');
    expect(film.request?.status).toBe('sent');
    expect(film.availability).toBe('requested');
  });

  it('asks nothing for a title the media server already has', async () => {
    const h = household();
    await h.put(h.adaKey, 'shared', 'movie/104');
    await h.later();
    expect(h.posted).toEqual([]);
    expect((await h.detail('movie/104')).request?.status).toBe('exists');
  });

  it('is not requested when undone within the window, and is when added again', async () => {
    const h = household();
    const res = await h.put(h.adaKey, 'shared', 'movie/101');
    const { changeId } = (await res.json()) as { changeId: string };
    await h.call(h.adaKey, `/api/lumos/changes/${changeId}/undo`, {
      method: 'POST',
    });
    await h.later();
    expect(h.posted).toEqual([]);
    expect((await h.detail('movie/101')).request?.status).toBe('dropped');

    await h.put(h.adaKey, 'shared', 'movie/101');
    await h.later();
    expect(h.posted).toHaveLength(1);
  });

  it('asks a series only for the chosen seasons, the first by default', async () => {
    const h = household();
    await h.put(h.adaKey, 'shared', 'tv/202');
    await h.later();
    expect(h.posted).toEqual([{ mediaType: 'tv', mediaId: 202, seasons: [1] }]);
  });

  it('keeps the list and retries while Seerr is down, then gives up visibly', async () => {
    const h = household();
    await h.later();
    h.setDown(true);
    expect((await h.put(h.adaKey, 'shared', 'movie/101')).status).toBe(503);

    // Known before the outage: the cached title lets the list take it.
    h.setDown(false);
    await h.detail('movie/101');
    h.setDown(true);
    expect((await h.put(h.adaKey, 'shared', 'movie/101')).status).toBe(200);
    await h.later();
    let film = await h.detail('movie/101');
    expect(film.request).toMatchObject({
      status: 'pending',
      error: 'Seerr is niet bereikbaar',
      attempts: 1,
    });
    for (let hour = 1; hour <= 60; hour++) await h.later(hour * 3_600_000);
    film = await h.detail('movie/101');
    expect(film.request?.status).toBe('failed');
    expect(h.posted).toEqual([]);
    expect(
      listResponse.parse(await h.json(h.adaKey, '/api/lumos/lists/shared'))
        .items,
    ).toHaveLength(1);

    h.setDown(false);
    const retry = await h.call(
      h.adaKey,
      '/api/lumos/requests/movie/101/retry',
      { method: 'POST' },
    );
    expect(retry.status).toBe(200);
    await h.lumos.requests?.run();
    expect(h.posted).toEqual([{ mediaType: 'movie', mediaId: 101 }]);
  });
});
