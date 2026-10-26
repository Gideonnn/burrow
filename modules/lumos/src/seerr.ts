import type {
  Availability,
  Credit,
  MediaType,
  Score,
  Trailer,
} from '@burrow/contracts';
import type {
  CatalogueHit,
  CatalogueProvider,
  CatalogueTitle,
  MediaRequester,
  MediaState,
  TitleRef,
} from './catalogue';

// The real catalogue: the household's Seerr, which serves TMDB's metadata,
// images and trailer references, Rotten Tomatoes and IMDb ratings, and what
// the media server has or is fetching. One service key for the household;
// it never leaves this file. Every answer is mapped field by field into
// Lumos's own types, never passed through, so nothing from Seerr's users or
// settings can reach a client.

const IMAGES = 'https://image.tmdb.org/t/p';
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

type MediaInfo = {
  status?: number;
  mediaType?: string;
  tmdbId?: number;
  requests?: { id?: number }[];
  jellyfinMediaId?: string | null;
  downloadStatus?: {
    size?: number;
    sizeLeft?: number;
    estimatedCompletionTime?: string;
  }[];
};

type Result = {
  id: number;
  mediaType?: string;
  title?: string;
  name?: string;
  releaseDate?: string;
  firstAirDate?: string;
  posterPath?: string | null;
  backdropPath?: string | null;
  profilePath?: string | null;
  overview?: string;
  popularity?: number;
  voteAverage?: number;
  voteCount?: number;
  genreIds?: number[];
  originalLanguage?: string;
  mediaInfo?: MediaInfo;
  knownFor?: Result[];
};

type Named = { id: number; name: string };

type Details = Result & {
  runtime?: number;
  episodeRunTime?: number[];
  numberOfSeasons?: number;
  numberOfSeason?: number;
  genres?: Named[];
  keywords?: Named[];
  createdBy?: Named[];
  relatedVideos?: {
    key?: string;
    site?: string;
    type?: string;
    url?: string;
  }[];
  credits?: {
    cast?: (Named & { order?: number })[];
    crew?: (Named & { job?: string })[];
  };
};

type Page = { results?: Result[] };

type Ratings = {
  rt?: { url?: string; criticsScore?: number; audienceScore?: number };
  imdb?: { url?: string; criticsScore?: number };
};

export type SeerrOptions = {
  url: string;
  apiKey: string;
  fetch?: typeof fetch;
  now?: () => Date;
};

type Cached<T> = { at: number; value: T };

const yearOf = (date?: string) => {
  const year = Number(date?.slice(0, 4));
  return Number.isInteger(year) && year > 0 ? year : null;
};

const image = (path: string | null | undefined, size: string) =>
  path ? `${IMAGES}/${size}${path}` : null;

const mediaTypeOf = (r: Result, fallback?: MediaType): MediaType | null => {
  const type = r.mediaType ?? fallback;
  return type === 'movie' || type === 'tv' ? type : null;
};

// Seerr's media status: 2 pending, 3 processing, 4 partly, 5 available.
// Processing alone does not prove a download, so only a live download
// status says "downloading".
export function availabilityOf(
  info: MediaInfo | undefined,
  released: string | undefined,
  today: string,
): Availability {
  switch (info?.status) {
    case 5:
      return 'available';
    case 4:
      return 'partially-available';
    case 3:
      if (info.downloadStatus?.length) return 'downloading';
      return released && released > today ? 'waiting-for-release' : 'requested';
    case 2:
      return 'requested';
    default:
      return 'not-requested';
  }
}

export class SeerrCatalogue implements CatalogueProvider, MediaRequester {
  readonly origin = 'live' as const;
  readonly name = 'Seerr';
  private readonly base: string;
  private readonly fetcher: typeof fetch;
  private readonly now: () => Date;
  private pool?: Cached<CatalogueTitle[]>;
  private pending?: Promise<CatalogueTitle[]>;
  private readonly titles = new Map<string, Cached<CatalogueTitle | null>>();
  private genres?: Cached<Map<number, string>>;

  constructor(private readonly options: SeerrOptions) {
    this.base = `${options.url.replace(/\/+$/, '')}/api/v1`;
    this.fetcher = options.fetch ?? fetch;
    this.now = options.now ?? (() => new Date());
  }

  private today() {
    return this.now().toISOString().slice(0, 10);
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
    return (await res.json()) as T;
  }

  private async genreNames() {
    if (this.genres && this.now().getTime() - this.genres.at < GENRE_TTL) {
      return this.genres.value;
    }
    const map = new Map<number, string>();
    for (const kind of ['movie', 'tv']) {
      const list = await this.call<Named[]>(`/genres/${kind}`, {
        language: LANGUAGE,
      }).catch(() => [] as Named[]);
      for (const g of list) map.set(g.id, g.name);
    }
    this.genres = { at: this.now().getTime(), value: map };
    return map;
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
    return {
      mediaType,
      tmdbId: r.id,
      title,
      year: yearOf(released),
      runtimeMinutes: null,
      seasons: null,
      genres: (r.genreIds ?? []).flatMap((id) => genres.get(id) ?? []),
      traits: [],
      language: r.originalLanguage ?? null,
      poster: image(r.posterPath, 'w342'),
      backdrop: image(r.backdropPath, 'w780'),
      availability: availabilityOf(r.mediaInfo, released, this.today()),
      popularity,
      synopsis: r.overview?.trim() || null,
      synopsisLanguage: r.overview?.trim() ? LANGUAGE : null,
      credits: [],
      scores: this.tmdbScore(r, mediaType),
      snippets: [],
      trailer: null,
      stills: [],
      stillsCredit: null,
      tmdbUrl: `https://www.themoviedb.org/${mediaType}/${r.id}`,
      download: null,
      mediaServerId: r.mediaInfo?.jellyfinMediaId || null,
    };
  }

  private tmdbScore(r: Result, mediaType: MediaType): Score[] {
    if (!r.voteCount || r.voteAverage === undefined) return [];
    return [
      {
        source: 'TMDB',
        label: null,
        value: Math.round(r.voteAverage * 10) / 10,
        scale: 'ten',
        votes: r.voteCount,
        votesAtLeast: false,
        asOf: this.today(),
        url: `https://www.themoviedb.org/${mediaType}/${r.id}`,
      },
    ];
  }

  // Popularity as Seerr orders it, scaled to 0..10 so Lumos's own weights
  // (the list, "more like this") still count next to it.
  private toTitles(results: Result[], genres: Map<number, string>) {
    const titles: CatalogueTitle[] = [];
    results.forEach((r, i) => {
      const t = this.fromResult(r, genres, 10 * (1 - i / results.length));
      if (t) titles.push(t);
    });
    return titles;
  }

  async candidates(): Promise<CatalogueTitle[]> {
    const now = this.now().getTime();
    if (this.pool && now - this.pool.at < POOL_TTL) return this.pool.value;
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
      const key = `${t.mediaType}:${t.tmdbId}`;
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
      const mediaType =
        m.mediaType === 'tv' ? 'tv' : m.mediaType === 'movie' ? 'movie' : null;
      if (!mediaType || !m.tmdbId || seen.has(`${mediaType}:${m.tmdbId}`)) {
        return [];
      }
      return [{ mediaType, tmdbId: m.tmdbId } as TitleRef];
    });
    const titles = await Promise.all(
      refs.map((ref) => this.title(ref).catch(() => undefined)),
    );
    return titles.flatMap((t) => (t ? [{ ...t, popularity: 1 }] : []));
  }

  async title(ref: TitleRef): Promise<CatalogueTitle | undefined> {
    const key = `${ref.mediaType}:${ref.tmdbId}`;
    const cached = this.titles.get(key);
    const now = this.now().getTime();
    if (cached && now - cached.at < TITLE_TTL) return cached.value ?? undefined;
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
    this.titles.delete(`${ref.mediaType}:${ref.tmdbId}`);
    this.pool = undefined;
  }

  private async loadTitle(ref: TitleRef): Promise<CatalogueTitle | null> {
    let d: Details;
    try {
      d = await this.call<Details>(`/${ref.mediaType}/${ref.tmdbId}`, {
        language: LANGUAGE,
      });
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
      credits: this.credits(d, ref.mediaType),
      scores: [...ratings, ...base.scores],
      trailer: this.trailer(d),
      stills: base.backdrop ? [image(d.backdropPath, 'w1280') as string] : [],
      stillsCredit: base.backdrop ? 'TMDB' : null,
      availability: availabilityOf(d.mediaInfo, released, this.today()),
      download: this.download(d.mediaInfo),
    };
  }

  private credits(d: Details, mediaType: MediaType): Credit[] {
    const makers =
      mediaType === 'tv'
        ? (d.createdBy ?? []).map((p) => ({ ...p, role: 'creator' as const }))
        : (d.credits?.crew ?? [])
            .filter((p) => p.job === 'Director')
            .map((p) => ({ ...p, role: 'director' as const }));
    const cast = [...(d.credits?.cast ?? [])]
      .sort((a, b) => (a.order ?? 99) - (b.order ?? 99))
      .slice(0, 8)
      .map((p) => ({ ...p, role: 'cast' as const }));
    const seen = new Set<string>();
    return [...makers.slice(0, 3), ...cast].flatMap((p) => {
      const key = `${p.role}:${p.id}`;
      if (seen.has(key)) return [];
      seen.add(key);
      return [{ id: String(p.id), name: p.name, role: p.role }];
    });
  }

  private trailer(d: Details): Trailer | null {
    const videos = (d.relatedVideos ?? []).filter(
      (v) => v.site === 'YouTube' && v.key && /^[\w-]{6,20}$/.test(v.key),
    );
    const video =
      videos.find((v) => v.type === 'Trailer') ??
      videos.find((v) => v.type === 'Teaser');
    if (!video?.key) return null;
    return {
      provider: 'youtube',
      key: video.key,
      url: `https://www.youtube.com/watch?v=${video.key}`,
      publisher: 'YouTube, via TMDB',
      language: null,
      checkedAt: this.today(),
    };
  }

  private download(info: MediaInfo | undefined) {
    const items = info?.downloadStatus ?? [];
    const size = items.reduce((n, i) => n + (i.size ?? 0), 0);
    if (!items.length || !size) return null;
    const left = items.reduce((n, i) => n + (i.sizeLeft ?? 0), 0);
    const eta = items
      .map((i) => i.estimatedCompletionTime)
      .filter((e): e is string => Boolean(e))
      .sort()
      .at(-1);
    return {
      progress: Math.max(0, Math.min(1, 1 - left / size)),
      eta: eta ?? null,
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

  async search(query: string) {
    const genres = await this.genreNames();
    const page = await this.call<Page>('/search', {
      query,
      page: 1,
      language: LANGUAGE,
    });
    const results = page.results ?? [];
    const hits: CatalogueHit[] = [];
    const seen = new Set<string>();
    const push = (t: CatalogueTitle | null, why: string | null) => {
      if (!t) return;
      const key = `${t.mediaType}:${t.tmdbId}`;
      if (seen.has(key)) return;
      seen.add(key);
      hits.push({ title: t, why });
    };
    results.forEach((r, i) => {
      if (r.mediaType === 'person') return;
      push(this.fromResult(r, genres, 10 - i / 2), null);
    });
    const people = results.filter((r) => r.mediaType === 'person' && r.name);
    for (const p of people) {
      for (const k of p.knownFor ?? []) {
        push(this.fromResult(k, genres, 1), `Werk van ${p.name}`);
      }
    }
    return {
      hits,
      credits: people
        .slice(0, 6)
        .map((p) => ({ id: String(p.id), name: p.name as string })),
    };
  }

  async credit(id: string) {
    if (!/^\d+$/.test(id)) return undefined;
    let person: { id: number; name?: string };
    try {
      person = await this.call(`/person/${id}`, { language: LANGUAGE });
    } catch (error) {
      if (error instanceof SeerrError && error.status === 404) return undefined;
      throw error;
    }
    const genres = await this.genreNames();
    const works = await this.call<{
      cast?: Result[];
      crew?: (Result & { job?: string })[];
    }>(`/person/${id}/combined_credits`, { language: LANGUAGE });
    const all = [
      ...(works.crew ?? []).filter((w) => w.job === 'Director'),
      ...(works.cast ?? []),
    ].sort((a, b) => (b.popularity ?? 0) - (a.popularity ?? 0));
    const seen = new Set<string>();
    const titles = this.toTitles(all, genres).filter((t) => {
      const key = `${t.mediaType}:${t.tmdbId}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
    return {
      credit: { id, name: person.name ?? '?' },
      titles: titles.slice(0, 40),
    };
  }

  // --- requests ---------------------------------------------------------------

  async state(ref: TitleRef): Promise<MediaState> {
    const d = await this.call<Details>(`/${ref.mediaType}/${ref.tmdbId}`, {
      language: LANGUAGE,
    });
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
}
