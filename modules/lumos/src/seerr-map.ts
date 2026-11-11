import type {
  Availability,
  CastMember,
  Credit,
  MediaType,
  Score,
  SeasonSummary,
  Trailer,
} from '@burrow/contracts';
import type { Download } from './catalogue';

// What Seerr answers, and how Lumos maps it field by field into its own
// types. Nothing is passed through, so nothing from Seerr's users or settings
// can reach a client.

export type MediaInfo = {
  id?: number;
  status?: number;
  // Radarr's or Sonarr's own id: set once one of them manages the title.
  externalServiceId?: number | null;
  mediaAddedAt?: string | null;
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

export type Result = {
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

export type Named = { id: number; name: string };

export type Details = Result & {
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

export type PersonRecord = {
  id: number;
  name?: string;
  profilePath?: string | null;
  biography?: string;
  birthday?: string | null;
  deathday?: string | null;
  placeOfBirth?: string | null;
  knownForDepartment?: string;
};

export type Page = { results?: Result[] };

export type Ratings = {
  rt?: { url?: string; criticsScore?: number; audienceScore?: number };
  imdb?: { url?: string; criticsScore?: number };
};

// The source's job titles, in Dutch; the rest of the crew stays out.
export const JOBS: Record<string, string> = {
  Director: 'Regie',
  Writer: 'Scenario',
  Screenplay: 'Scenario',
  Story: 'Verhaal',
  Creator: 'Maker',
  'Original Music Composer': 'Muziek',
  'Director of Photography': 'Camera',
};

const IMAGES = 'https://image.tmdb.org/t/p';

export const image = (path: string | null | undefined, size: string) =>
  path ? `${IMAGES}/${size}${path}` : null;

// "en" becomes "Engels": the original language as a word, not a code.
const languageNames = new Intl.DisplayNames(['nl'], { type: 'language' });
export const languageName = (code: string | undefined | null) => {
  if (!code) return null;
  try {
    const name = languageNames.of(code) ?? code;
    return name.charAt(0).toUpperCase() + name.slice(1);
  } catch {
    return code;
  }
};

export const yearOf = (date?: string) => {
  const year = Number(date?.slice(0, 4));
  return Number.isInteger(year) && year > 0 ? year : null;
};

export const mediaTypeOf = (
  r: { mediaType?: string },
  fallback?: MediaType,
): MediaType | null => {
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

export function downloadOf(info: MediaInfo | undefined): Download | null {
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
    bytesLeft: left,
  };
}

export function tmdbScore(
  r: Result,
  mediaType: MediaType,
  asOf: string,
): Score[] {
  if (!r.voteCount || r.voteAverage === undefined) return [];
  return [
    {
      source: 'TMDB',
      label: null,
      value: Math.round(r.voteAverage * 10) / 10,
      scale: 'ten',
      votes: r.voteCount,
      votesAtLeast: false,
      asOf,
      url: `https://www.themoviedb.org/${mediaType}/${r.id}`,
    },
  ];
}

const byOrder = (d: Details) =>
  [...(d.credits?.cast ?? [])].sort(
    (a, b) => (a.order ?? 99) - (b.order ?? 99),
  );

export const castOf = (d: Details): CastMember[] =>
  byOrder(d)
    .slice(0, 24)
    .map((p) => ({
      id: String(p.id),
      name: p.name,
      part: p.character?.trim() || null,
      photo: image(p.profilePath, 'w185'),
    }));

// The makers: directors, writers and creators, one line per person with
// every job they had ("Regie, Scenario").
export function crewOf(d: Details, mediaType: MediaType): CastMember[] {
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

export function creditsOf(d: Details, mediaType: MediaType): Credit[] {
  const makers =
    mediaType === 'tv'
      ? (d.createdBy ?? []).map((p) => ({ ...p, role: 'creator' as const }))
      : (d.credits?.crew ?? [])
          .filter((p) => p.job === 'Director')
          .map((p) => ({ ...p, role: 'director' as const }));
  const cast = byOrder(d)
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

export const seasonsOf = (d: Details): SeasonSummary[] =>
  (d.seasons ?? [])
    .filter((s) => (s.seasonNumber ?? 0) > 0)
    .map((s) => ({
      number: s.seasonNumber ?? 0,
      name: s.name?.trim() || `Seizoen ${s.seasonNumber}`,
      episodes: s.episodeCount ?? null,
      year: yearOf(s.airDate ?? undefined),
      poster: image(s.posterPath, 'w185'),
    }));

// YouTube only, "Trailer" before "Teaser".
export function trailerOf(d: Details, checkedAt: string): Trailer | null {
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
    checkedAt,
  };
}
