import type {
  Availability,
  Credit,
  MediaType,
  Score,
  Trailer,
} from '@burrow/contracts';
import type {
  BrowsePage,
  BrowseQuery,
  CatalogueHit,
  CatalogueProvider,
  CatalogueTitle,
  MediaRequester,
  MediaState,
  Person,
  TitleRef,
} from './catalogue';

// The real catalogue: the household's Seerr, which serves TMDB's metadata,
// images and trailer references, Rotten Tomatoes and IMDb ratings, and what
// the media server has or is fetching. One service key for the household;
// it never leaves this file. Every answer is mapped field by field into
// Lumos's own types, never passed through, so nothing from Seerr's users or
// settings can reach a client.

const IMAGES = 'https://image.tmdb.org/t/p';

// "en" becomes "Engels": the original language as a word, not a code.
const languageNames = new Intl.DisplayNames(['nl'], { type: 'language' });
const languageName = (code: string | undefined | null) => {
  if (!code) return null;
  try {
    const name = languageNames.of(code) ?? code;
    return name.charAt(0).toUpperCase() + name.slice(1);
  } catch {
    return code;
  }
};
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
  numberOfEpisodes?: number;
  genres?: Named[];
  keywords?: Named[];
  createdBy?: (Named & { profilePath?: string | null })[];
  relatedVideos?: {
    key?: string;
    site?: string;
    type?: string;
    url?: string;
  }[];
  credits?: {
    cast?: (Named & {
      order?: number;
      character?: string;
      profilePath?: string | null;
    })[];
    crew?: (Named & { job?: string; profilePath?: string | null })[];
  };
  tagline?: string;
  status?: string;
  originalTitle?: string;
  originalName?: string;
  lastAirDate?: string;
  budget?: number;
  revenue?: number;
  productionCompanies?: Named[];
  networks?: Named[];
  collection?: Named | null;
  seasons?: {
    seasonNumber?: number;
    name?: string;
    episodeCount?: number;
    airDate?: string | null;
    posterPath?: string | null;
  }[];
};

type PersonRecord = {
  id: number;
  name?: string;
  profilePath?: string | null;
  biography?: string;
  birthday?: string | null;
  deathday?: string | null;
  placeOfBirth?: string | null;
  knownForDepartment?: string;
};

// The source's job titles, in Dutch; the rest of the crew stays out.
const JOBS: Record<string, string> = {
  Director: 'Regie',
  Writer: 'Scenario',
  Screenplay: 'Scenario',
  Story: 'Verhaal',
  Creator: 'Maker',
  'Original Music Composer': 'Muziek',
  'Director of Photography': 'Camera',
};

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

  private async genreData() {
    if (this.genres && this.now().getTime() - this.genres.at < GENRE_TTL) {
      return this.genres.value;
    }
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
    return {
      mediaType,
      tmdbId: r.id,
      title,
      year: yearOf(released),
      runtimeMinutes: null,
      seasons: null,
      genres: (r.genreIds ?? []).flatMap((id) => genres.get(id) ?? []),
      traits: [],
      language: languageName(r.originalLanguage),
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
      cast: [...(d.credits?.cast ?? [])]
        .sort((a, b) => (a.order ?? 99) - (b.order ?? 99))
        .slice(0, 24)
        .map((p) => ({
          id: String(p.id),
          name: p.name,
          part: p.character?.trim() || null,
          photo: image(p.profilePath, 'w185'),
        })),
      crew: this.crew(d, ref.mediaType),
      seasonList: (d.seasons ?? [])
        .filter((s) => (s.seasonNumber ?? 0) > 0)
        .map((s) => ({
          number: s.seasonNumber ?? 0,
          name: s.name?.trim() || `Seizoen ${s.seasonNumber}`,
          episodes: s.episodeCount ?? null,
          year: yearOf(s.airDate ?? undefined),
          poster: image(s.posterPath, 'w185'),
        })),
      episodes: d.numberOfEpisodes ?? null,
    };
  }

  // The makers: directors, writers and creators, one line per person with
  // every job they had ("Regie, Scenario").
  private crew(d: Details, mediaType: MediaType) {
    const people = new Map<
      string,
      { name: string; parts: string[]; photo: string | null }
    >();
    const add = (
      id: number,
      name: string,
      part: string,
      photo?: string | null,
    ) => {
      const entry = people.get(String(id)) ?? {
        name,
        parts: [],
        photo: image(photo, 'w185'),
      };
      if (!entry.parts.includes(part)) entry.parts.push(part);
      people.set(String(id), entry);
    };
    if (mediaType === 'tv') {
      for (const p of d.createdBy ?? [])
        add(p.id, p.name, 'Maker', p.profilePath);
    }
    for (const p of d.credits?.crew ?? []) {
      const part = p.job && JOBS[p.job];
      if (part) add(p.id, p.name, part, p.profilePath);
    }
    return [...people].slice(0, 8).map(([id, p]) => ({
      id,
      name: p.name,
      part: p.parts.join(', '),
      photo: p.photo,
    }));
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
        part: parts.get(`${t.mediaType}:${t.tmdbId}`)?.join(', ') ?? null,
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
    const key = `${ref.mediaType}:${ref.tmdbId}`;
    const now = this.now().getTime();
    const hit = this.relatedCache.get(key);
    if (hit && now - hit.at < TITLE_TTL) return hit.value;
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
    const hit = this.browseCache.get(key);
    if (hit && now - hit.at < POOL_TTL) return hit.value;
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
