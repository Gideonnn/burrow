import type { MediaType, Score } from '@burrow/contracts';
import {
  bareTitle,
  type BrowsePage,
  type BrowseQuery,
  type CatalogueProvider,
  type CatalogueTitle,
  type Holding,
  type MediaRequester,
  type MediaState,
  NotRemovable,
  type Person,
  refKey,
  type TitleRef,
} from './catalogue';
import {
  availabilityOf,
  castOf,
  creditsOf,
  crewOf,
  type Details,
  downloadOf,
  image,
  JOBS,
  languageName,
  type MediaInfo,
  mediaTypeOf,
  type Named,
  type Page,
  type PersonRecord,
  type Ratings,
  type Result,
  seasonsOf,
  tmdbScore,
  trailerOf,
  yearOf,
} from './seerr-map';

// The real catalogue: the household's Seerr, which serves TMDB's metadata,
// images and trailer references, Rotten Tomatoes and IMDb ratings, and what
// the media server has or is fetching. One service key for the household;
// it never leaves this file. Answers are mapped in `seerr-map.ts`.

const LANGUAGE = 'en';
const POOL_TTL = 10 * 60_000;
const TITLE_TTL = 5 * 60_000;
const GENRE_TTL = 24 * 60 * 60_000;

export class SeerrError extends Error {
  constructor(
    message: string,
    readonly status: number | null = null,
  ) {
    super(message);
  }
}

const SORTS = {
  movie: {
    popular: 'popularity.desc',
    new: 'primary_release_date.desc',
    top: 'vote_average.desc',
  },
  tv: {
    popular: 'popularity.desc',
    new: 'first_air_date.desc',
    top: 'vote_average.desc',
  },
} as const;

export type SeerrOptions = {
  url: string;
  apiKey: string;
  fetch?: typeof fetch;
  now?: () => Date;
};

type Cached<T> = { at: number; value: T };

export class SeerrCatalogue implements CatalogueProvider, MediaRequester {
  readonly origin = 'live' as const;
  readonly name = 'Seerr';
  private readonly base: string;
  private readonly fetcher: typeof fetch;
  private readonly now: () => Date;
  private pool?: Cached<CatalogueTitle[]>;
  private pending?: Promise<CatalogueTitle[]>;
  private readonly titles = new Map<string, Cached<CatalogueTitle | null>>();
  private genres?: Cached<{
    map: Map<number, string>;
    lists: { movie: Named[]; tv: Named[] };
  }>;
  private readonly relatedCache = new Map<string, Cached<CatalogueTitle[]>>();
  private readonly browseCache = new Map<string, Cached<BrowsePage>>();

  constructor(private readonly options: SeerrOptions) {
    this.base = `${options.url.replace(/\/+$/, '')}/api/v1`;
    this.fetcher = options.fetch ?? fetch;
    this.now = options.now ?? (() => new Date());
  }

  private today() {
    return this.now().toISOString().slice(0, 10);
  }

  private fresh<T>(cached: Cached<T> | undefined, ttl: number) {
    return cached && this.now().getTime() - cached.at < ttl
      ? cached
      : undefined;
  }

  private details(ref: TitleRef) {
    return this.call<Details>(`/${ref.mediaType}/${ref.tmdbId}`, {
      language: LANGUAGE,
    });
  }

  private async call<T>(
    path: string,
    params: Record<string, string | number | undefined> = {},
    init: { method?: string; body?: unknown } = {},
  ): Promise<T> {
    const query = Object.entries(params)
      .filter(([, v]) => v !== undefined)
      .map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`)
      .join('&');
    let res: Response;
    try {
      res = await this.fetcher(
        `${this.base}${path}${query ? `?${query}` : ''}`,
        {
          method: init.method ?? 'GET',
          headers: {
            'X-Api-Key': this.options.apiKey,
            Accept: 'application/json',
            ...(init.body === undefined
              ? {}
              : { 'Content-Type': 'application/json' }),
          },
          body: init.body === undefined ? undefined : JSON.stringify(init.body),
          signal: AbortSignal.timeout(15_000),
        },
      );
    } catch {
      throw new SeerrError('Seerr is niet bereikbaar');
    }
    if (!res.ok) {
      throw new SeerrError(`Seerr antwoordde HTTP ${res.status}`, res.status);
    }
    // A delete answers 204 without a body.
    const text = await res.text();
    return (text ? JSON.parse(text) : undefined) as T;
  }

  private async genreData() {
    const cached = this.fresh(this.genres, GENRE_TTL);
    if (cached) return cached.value;
    const lists = { movie: [] as Named[], tv: [] as Named[] };
    for (const kind of ['movie', 'tv'] as const) {
      // Genre names in Dutch: the mood chips and the labels speak Dutch.
      lists[kind] = await this.call<Named[]>(`/genres/${kind}`, {
        language: 'nl',
      }).catch(() => [] as Named[]);
    }
    const map = new Map<number, string>();
    for (const g of [...lists.movie, ...lists.tv]) map.set(g.id, g.name);
    this.genres = { at: this.now().getTime(), value: { map, lists } };
    return this.genres.value;
  }

  private async genreNames() {
    return (await this.genreData()).map;
  }

  private async genreList(mediaType: MediaType) {
    return (await this.genreData()).lists[mediaType].map((g) => ({
      id: String(g.id),
      name: g.name,
    }));
  }

  private fromResult(
    r: Result,
    genres: Map<number, string>,
    popularity: number,
    fallback?: MediaType,
  ): CatalogueTitle | null {
    const mediaType = mediaTypeOf(r, fallback);
    const title = r.title ?? r.name;
    if (!mediaType || !title) return null;
    const released = r.releaseDate ?? r.firstAirDate;
    return bareTitle({
      mediaType,
      tmdbId: r.id,
      title,
      year: yearOf(released),
      genres: (r.genreIds ?? []).flatMap((id) => genres.get(id) ?? []),
      language: languageName(r.originalLanguage),
      poster: image(r.posterPath, 'w342'),
      backdrop: image(r.backdropPath, 'w780'),
      availability: availabilityOf(r.mediaInfo, released, this.today()),
      popularity,
      synopsis: r.overview?.trim() || null,
      synopsisLanguage: r.overview?.trim() ? LANGUAGE : null,
      scores: tmdbScore(r, mediaType, this.today()),
      tmdbUrl: `https://www.themoviedb.org/${mediaType}/${r.id}`,
      download: null,
      mediaServerId: r.mediaInfo?.jellyfinMediaId || null,
    });
  }

  // Popularity as Seerr orders it, scaled to 0..10 so Lumos's own weights
  // (the list, "more like this") still count next to it.
  private toTitles(
    results: Result[],
    genres: Map<number, string>,
    fallback?: MediaType,
  ) {
    const titles: CatalogueTitle[] = [];
    results.forEach((r, i) => {
      const t = this.fromResult(
        r,
        genres,
        10 * (1 - i / results.length),
        fallback,
      );
      if (t) titles.push(t);
    });
    return titles;
  }

  async candidates(): Promise<CatalogueTitle[]> {
    const cached = this.fresh(this.pool, POOL_TTL);
    if (cached) return cached.value;
    this.pending ??= this.loadPool().finally(() => {
      this.pending = undefined;
    });
    try {
      return await this.pending;
    } catch (error) {
      // The last pool beats an empty page while Seerr is down.
      if (this.pool) return this.pool.value;
      throw error;
    }
  }

  private async loadPool() {
    const genres = await this.genreNames();
    const pages = await Promise.all([
      this.call<Page>('/discover/trending', { page: 1, language: LANGUAGE }),
      this.call<Page>('/discover/trending', { page: 2, language: LANGUAGE }),
      this.call<Page>('/discover/movies', { page: 1, language: LANGUAGE }),
      this.call<Page>('/discover/tv', { page: 1, language: LANGUAGE }),
    ]);
    const seen = new Set<string>();
    const pool: CatalogueTitle[] = [];
    const results = pages.flatMap((p) => p.results ?? []);
    for (const t of this.toTitles(results, genres)) {
      const key = refKey(t);
      if (seen.has(key)) continue;
      seen.add(key);
      pool.push(t);
    }
    for (const t of await this.library(seen)) pool.push(t);
    this.pool = { at: this.now().getTime(), value: pool };
    return pool;
  }

  // What the media server already has, newest first, so "Klaar in Jellyfin"
  // shows the library and not only what happens to be trending.
  private async library(seen: Set<string>) {
    const page = await this.call<{ results?: MediaInfo[] }>('/media', {
      filter: 'available',
      take: 40,
      sort: 'mediaAdded',
    }).catch(() => ({ results: [] as MediaInfo[] }));
    const refs = (page.results ?? []).flatMap((m) => {
      const mediaType = mediaTypeOf(m);
      if (!mediaType || !m.tmdbId) return [];
      const ref = { mediaType, tmdbId: m.tmdbId };
      return seen.has(refKey(ref)) ? [] : [ref];
    });
    const titles = await Promise.all(
      refs.map((ref) => this.title(ref).catch(() => undefined)),
    );
    return titles.flatMap((t) => (t ? [{ ...t, popularity: 1 }] : []));
  }

  async title(ref: TitleRef): Promise<CatalogueTitle | undefined> {
    const key = refKey(ref);
    const cached = this.titles.get(key);
    const now = this.now().getTime();
    if (this.fresh(cached, TITLE_TTL)) return cached?.value ?? undefined;
    try {
      const value = await this.loadTitle(ref);
      this.titles.set(key, { at: now, value });
      return value ?? undefined;
    } catch (error) {
      if (cached) return cached.value ?? undefined;
      throw error;
    }
  }

  // After a request, so the next read shows its status.
  forget(ref: TitleRef) {
    this.titles.delete(refKey(ref));
    this.pool = undefined;
  }

  private async loadTitle(ref: TitleRef): Promise<CatalogueTitle | null> {
    let d: Details;
    try {
      d = await this.details(ref);
    } catch (error) {
      if (error instanceof SeerrError && error.status === 404) return null;
      throw error;
    }
    const genres = new Map((d.genres ?? []).map((g) => [g.id, g.name]));
    const base = this.fromResult(
      { ...d, genreIds: [...genres.keys()] },
      genres,
      d.popularity ? Math.min(10, Math.log10(d.popularity + 1) * 3) : 0,
      ref.mediaType,
    );
    if (!base) return null;
    const ratings = await this.ratings(ref);
    const released = d.releaseDate ?? d.firstAirDate;
    return {
      ...base,
      runtimeMinutes: d.runtime || d.episodeRunTime?.[0] || null,
      seasons:
        ref.mediaType === 'tv'
          ? (d.numberOfSeasons ?? d.numberOfSeason ?? null)
          : null,
      traits: (d.keywords ?? []).slice(0, 6).map((k) => k.name),
      credits: creditsOf(d, ref.mediaType),
      scores: [...ratings, ...base.scores],
      trailer: trailerOf(d, this.today()),
      stills: base.backdrop ? [image(d.backdropPath, 'w1280') as string] : [],
      stillsCredit: base.backdrop ? 'TMDB' : null,
      availability: availabilityOf(d.mediaInfo, released, this.today()),
      download: downloadOf(d.mediaInfo),
      addedAt: d.mediaInfo?.mediaAddedAt ?? null,
      removable: d.mediaInfo?.externalServiceId != null,
      tagline: d.tagline?.trim() || null,
      originalTitle: (() => {
        const original = d.originalTitle ?? d.originalName;
        return original && original !== base.title ? original : null;
      })(),
      status: d.status ?? null,
      releaseDate: released ?? null,
      lastAired: d.lastAirDate ?? null,
      budget: d.budget || null,
      revenue: d.revenue || null,
      studios: (d.productionCompanies ?? d.networks ?? [])
        .map((n) => n.name)
        .filter(Boolean)
        .slice(0, 4),
      collection: d.collection
        ? { id: d.collection.id, name: d.collection.name }
        : null,
      cast: castOf(d),
      crew: crewOf(d, ref.mediaType),
      seasonList: seasonsOf(d),
      episodes: d.numberOfEpisodes ?? null,
    };
  }

  private async ratings(ref: TitleRef): Promise<Score[]> {
    const asOf = this.today();
    const scores: Score[] = [];
    const percent = (
      label: string,
      value: number | undefined,
      url?: string,
    ) => {
      if (typeof value !== 'number') return;
      scores.push({
        source: 'Rotten Tomatoes',
        label,
        value,
        scale: 'percent',
        votes: null,
        votesAtLeast: false,
        asOf,
        url: url ?? null,
      });
    };
    try {
      if (ref.mediaType === 'movie') {
        const r = await this.call<Ratings>(
          `/movie/${ref.tmdbId}/ratingscombined`,
        );
        if (typeof r.imdb?.criticsScore === 'number') {
          scores.push({
            source: 'IMDb',
            label: null,
            value: r.imdb.criticsScore,
            scale: 'ten',
            votes: null,
            votesAtLeast: false,
            asOf,
            url: r.imdb.url ?? null,
          });
        }
        percent('Critics', r.rt?.criticsScore, r.rt?.url);
        percent('Audience', r.rt?.audienceScore, r.rt?.url);
      } else {
        const r = await this.call<{ url?: string; criticsScore?: number }>(
          `/tv/${ref.tmdbId}/ratings`,
        );
        percent('Critics', r.criticsScore, r.url);
      }
    } catch {
      // No rating at the source is common; the title shows without one.
    }
    return scores;
  }

  // Seerr hands out TMDB's order a page at a time: a short word brings
  // obscure exact matches, series and people first. Three pages, ranked
  // by how well the name matches and how well known the title is.
  async search(query: string, known: CatalogueTitle[] = []) {
    const genres = await this.genreNames();
    const pages = await Promise.all(
      [1, 2, 3].map((page) =>
        this.call<Page>('/search', { query, page, language: LANGUAGE }).catch(
          (error: unknown) => {
            if (page === 1) throw error;
            return {} as Page;
          },
        ),
      ),
    );
    const results = pages.flatMap((p) => p.results ?? []);
    const ranked: {
      title: CatalogueTitle;
      why: string | null;
      score: number;
    }[] = [];
    const seen = new Set<string>();
    const push = (r: Result, why: string | null, fit: number) => {
      const t = this.fromResult(r, genres, 0);
      if (!t) return;
      const key = `${t.mediaType}:${t.tmdbId}`;
      if (seen.has(key)) return;
      seen.add(key);
      ranked.push({
        title: t,
        why,
        score: searchScore(r, fit, t.availability),
      });
    };
    for (const r of results) {
      if (r.mediaType === 'person') continue;
      push(r, null, nameFit(r.title ?? r.name ?? '', query));
    }
    const people = results
      .filter((r) => r.mediaType === 'person' && r.name)
      .sort((a, b) => (b.popularity ?? 0) - (a.popularity ?? 0));
    for (const p of people.slice(0, 3)) {
      const fit = Math.max(0, nameFit(p.name ?? '', query) - 0.5);
      for (const k of p.knownFor ?? []) push(k, `Werk van ${p.name}`, fit);
    }
    // TMDB matches whole words only ('dead' misses Deadpool); the titles
    // Lumos knows (trending, held, listed) match by the start of a word.
    for (const t of known) {
      const key = `${t.mediaType}:${t.tmdbId}`;
      const fit = nameFit(t.title, query);
      if (seen.has(key) || fit < 2.5) continue;
      seen.add(key);
      const held = t.availability === 'available' ? 1 : 0;
      ranked.push({ title: t, why: null, score: fit * 1.5 + 3.5 + held });
    }
    ranked.sort((a, b) => b.score - a.score);
    return {
      hits: ranked.map(({ title, why }, i) => ({
        title: { ...title, popularity: 10 * (1 - i / ranked.length) },
        why,
      })),
      credits: people
        .slice(0, 6)
        .map((p) => ({ id: String(p.id), name: p.name as string })),
    };
  }

  // Who someone is and what they made, the most popular first, each title
  // once with every part they had in it.
  async person(id: string): Promise<Person | undefined> {
    if (!/^\d+$/.test(id)) return undefined;
    let person: PersonRecord;
    try {
      person = await this.call(`/person/${id}`, { language: LANGUAGE });
    } catch (error) {
      if (error instanceof SeerrError && error.status === 404) return undefined;
      throw error;
    }
    const genres = await this.genreNames();
    const works = await this.call<{
      cast?: (Result & { character?: string })[];
      crew?: (Result & { job?: string })[];
    }>(`/person/${id}/combined_credits`, { language: LANGUAGE });
    const parts = new Map<string, string[]>();
    const results = new Map<string, Result>();
    const note = (r: Result, part: string | null) => {
      const key = `${r.mediaType}:${r.id}`;
      if (!results.has(key)) results.set(key, r);
      if (part) {
        const list = parts.get(key) ?? [];
        if (!list.includes(part)) list.push(part);
        parts.set(key, list);
      }
    };
    for (const w of works.crew ?? []) {
      const part = w.job && JOBS[w.job];
      if (part) note(w, part);
    }
    for (const w of works.cast ?? []) {
      note(w, w.character?.trim() ? `als ${w.character.trim()}` : null);
    }
    const ordered = [...results.values()].sort(
      (a, b) => (b.popularity ?? 0) - (a.popularity ?? 0),
    );
    const titles = this.toTitles(ordered, genres)
      .slice(0, 80)
      .map((t) => ({
        ...t,
        part: parts.get(refKey(t))?.join(', ') ?? null,
      }));
    return {
      id,
      name: person.name ?? '?',
      photo: image(person.profilePath, 'w342'),
      biography: person.biography?.trim() || null,
      birthday: person.birthday ?? null,
      deathday: person.deathday ?? null,
      placeOfBirth: person.placeOfBirth ?? null,
      known: person.knownForDepartment ?? null,
      titles,
    };
  }

  // What TMDB puts next to a title: its recommendations first, then what it
  // calls similar, each title once. Kept for the title's cache period.
  async related(ref: TitleRef): Promise<CatalogueTitle[]> {
    const key = refKey(ref);
    const now = this.now().getTime();
    const hit = this.fresh(this.relatedCache.get(key), TITLE_TTL);
    if (hit) return hit.value;
    const genres = await this.genreNames();
    const page = (what: string) =>
      this.call<Page>(`/${ref.mediaType}/${ref.tmdbId}/${what}`, {
        page: 1,
        language: LANGUAGE,
      }).catch(() => ({ results: [] }) as Page);
    const [recommended, similar] = await Promise.all([
      page('recommendations'),
      page('similar'),
    ]);
    const seen = new Set<string>([key]);
    const results = [
      ...(recommended.results ?? []),
      ...(similar.results ?? []),
    ].filter((r) => {
      const k = `${r.mediaType ?? ref.mediaType}:${r.id}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
    const value = this.toTitles(results, genres, ref.mediaType).slice(0, 24);
    this.relatedCache.set(key, { at: now, value });
    this.trim(this.relatedCache);
    return value;
  }

  // A page of films or series the way TMDB sorts them, with the filters
  // Seerr passes through: genre, original language, dates and votes.
  async browse(q: BrowseQuery): Promise<BrowsePage> {
    const key = JSON.stringify(q);
    const now = this.now().getTime();
    const hit = this.fresh(this.browseCache.get(key), POOL_TTL);
    if (hit) return hit.value;
    const genres = await this.genreNames();
    const movie = q.mediaType === 'movie';
    const today = this.today();
    const date = movie ? 'primaryReleaseDate' : 'firstAirDate';
    const params: Record<string, string | number | undefined> = {
      page: q.page,
      language: q.language ?? LANGUAGE,
      genre: q.genre,
    };
    let path = movie ? '/discover/movies' : '/discover/tv';
    const span = (from: number, to: number) => {
      params[`${date}Gte`] = `${from}-01-01`;
      params[`${date}Lte`] = `${to}-12-31`;
    };
    if (q.decade) span(q.decade, q.decade + 9);
    if (q.year) span(q.year, q.year);
    const sorts = SORTS[q.mediaType];
    switch (q.sort) {
      case 'popular':
        params.sortBy = sorts.popular;
        break;
      case 'new':
        params.sortBy = sorts.new;
        params[`${date}Lte`] = today;
        params.voteCountGte = movie ? 20 : 5;
        break;
      case 'upcoming':
        params.sortBy = sorts.popular;
        params[`${date}Gte`] = today;
        break;
      case 'top':
        params.sortBy = sorts.top;
        params.voteCountGte = movie ? 1000 : 300;
        break;
      case 'gems':
        params.sortBy = sorts.top;
        params.voteCountGte = 200;
        params.voteCountLte = 3000;
        params.voteAverageGte = 7.3;
        break;
      case 'trending':
        path = '/discover/trending';
        break;
    }
    const page = await this.call<Page & { page?: number; totalPages?: number }>(
      path,
      params,
    );
    let results = page.results ?? [];
    if (q.sort === 'trending') {
      results = results.filter((r) => mediaTypeOf(r) === q.mediaType);
    }
    const value: BrowsePage = {
      page: page.page ?? q.page,
      totalPages: Math.max(1, Math.min(page.totalPages ?? 1, 500)),
      items: this.toTitles(results, genres, q.mediaType),
      genres: await this.genreList(q.mediaType),
    };
    this.browseCache.set(key, { at: now, value });
    this.trim(this.browseCache);
    return value;
  }

  private trim<T>(cache: Map<string, Cached<T>>, limit = 200) {
    while (cache.size > limit) {
      const oldest = cache.keys().next().value;
      if (oldest === undefined) break;
      cache.delete(oldest);
    }
  }

  // --- requests ---------------------------------------------------------------

  async state(ref: TitleRef): Promise<MediaState> {
    const d = await this.details(ref);
    const status = d.mediaInfo?.status ?? 1;
    return {
      known: status >= 2,
      requestId: d.mediaInfo?.requests?.[0]?.id ?? null,
    };
  }

  // The household's request with the media server's own defaults (quality
  // profile, folder, 4K or 1080p). Seerr answers 409 when it already exists.
  async request(ref: TitleRef, seasons: number[] | null) {
    try {
      const made = await this.call<{ id?: number }>(
        '/request',
        {},
        {
          method: 'POST',
          body: {
            mediaType: ref.mediaType,
            mediaId: ref.tmdbId,
            ...(ref.mediaType === 'tv' ? { seasons: seasons ?? [1] } : {}),
          },
        },
      );
      return { requestId: made.id ?? null, existed: false };
    } catch (error) {
      if (error instanceof SeerrError && error.status === 409) {
        return { requestId: null, existed: true };
      }
      throw error;
    } finally {
      this.forget(ref);
    }
  }

  // --- managing -------------------------------------------------------------

  private async media(filter: string, sort?: string) {
    const all: MediaInfo[] = [];
    for (let page = 0; page < 10; page++) {
      const answer = await this.call<{
        pageInfo?: { pages?: number };
        results?: MediaInfo[];
      }>('/media', { filter, sort, take: 100, skip: page * 100 });
      all.push(...(answer.results ?? []));
      if (page + 1 >= (answer.pageInfo?.pages ?? 1)) break;
    }
    return all;
  }

  // The titles come from the cache; status and download never do, so the
  // page shows how far a download is right now.
  private async holding(info: MediaInfo): Promise<Holding | null> {
    const mediaType = mediaTypeOf(info);
    if (!mediaType || !info.tmdbId) return null;
    const title = await this.title({ mediaType, tmdbId: info.tmdbId }).catch(
      () => undefined,
    );
    if (!title) return null;
    return {
      title: {
        ...title,
        availability: availabilityOf(
          info,
          title.releaseDate ?? undefined,
          this.today(),
        ),
      },
      download: downloadOf(info),
      addedAt: info.mediaAddedAt ?? null,
      removable: info.externalServiceId != null,
    };
  }

  async holdings() {
    const [pending, processing, held] = await Promise.all([
      this.media('pending'),
      this.media('processing'),
      this.media('allavailable', 'mediaAdded'),
    ]);
    // A series partly in the library may still be fetching its next season.
    const fetching = held.filter((m) => m.downloadStatus?.length);
    const all = async (infos: MediaInfo[]) =>
      (await Promise.all(infos.map((m) => this.holding(m)))).filter(
        (h): h is Holding => h !== null,
      );
    return {
      busy: await all([...processing, ...pending, ...fetching]),
      library: await all(held),
    };
  }

  // Seerr asks Radarr or Sonarr to delete the title with its files, then
  // forgets it, requests included, so it can be asked for again.
  async remove(ref: TitleRef) {
    try {
      const info = (await this.details(ref)).mediaInfo;
      if (!info?.id || (info.status ?? 1) < 2) {
        throw new NotRemovable('Seerr heeft deze titel niet');
      }
      if (info.externalServiceId == null) {
        throw new NotRemovable(
          ref.mediaType === 'movie'
            ? 'Radarr beheert deze film niet, dus Lumos kan hem niet verwijderen'
            : 'Sonarr beheert deze serie niet, dus Lumos kan hem niet verwijderen',
        );
      }
      await this.call(`/media/${info.id}/file`, {}, { method: 'DELETE' });
      await this.call(`/media/${info.id}`, {}, { method: 'DELETE' });
    } finally {
      this.forget(ref);
    }
  }
}

const fold = (text: string) =>
  text
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

// 4 the whole name, 3 its start, 2.75 a whole word, 2.5 the start of a
// word, 2 every typed word starts a word, 1.5 inside a word, 0 elsewhere.
function nameFit(name: string, query: string): number {
  const n = fold(name);
  const q = fold(query);
  if (!q || !n) return 0;
  if (n === q) return 4;
  if (n.startsWith(q)) return 3;
  const words = n.split(' ');
  if (` ${n} `.includes(` ${q} `)) return 2.75;
  if (` ${n}`.includes(` ${q}`)) return 2.5;
  const typed = q.split(' ');
  if (typed.every((t) => words.some((w) => w.startsWith(t)))) return 2;
  return n.includes(q) ? 1.5 : 0;
}

function searchScore(r: Result, fit: number, availability: string): number {
  const held = availability === 'available' ? 1 : 0;
  return (
    fit * 1.5 +
    Math.log10(1 + (r.voteCount ?? 0)) +
    0.3 * Math.log10(1 + (r.popularity ?? 0)) +
    held
  );
}
