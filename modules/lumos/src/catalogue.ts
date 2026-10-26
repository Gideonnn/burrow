import type {
  Availability,
  BrowseSort,
  CastMember,
  Credit,
  DataOrigin,
  MediaType,
  PersonDetail,
  Score,
  SeasonSummary,
  Snippet,
  Trailer,
} from '@burrow/contracts';

export type TitleRef = { mediaType: MediaType; tmdbId: number };

export const refKey = (ref: TitleRef) => `${ref.mediaType}:${ref.tmdbId}`;

// A title as a provider knows it, before Lumos adds lists and verdicts.
export type CatalogueTitle = TitleRef & {
  title: string;
  year: number | null;
  runtimeMinutes: number | null;
  seasons: number | null;
  genres: string[];
  traits: string[];
  language: string | null;
  poster: string | null;
  backdrop: string | null;
  availability: Availability;
  // Higher is more popular; the provider's own order.
  popularity: number;
  synopsis: string | null;
  synopsisLanguage: string | null;
  credits: Credit[];
  scores: Score[];
  snippets: Snippet[];
  trailer: Trailer | null;
  stills: string[];
  stillsCredit: string | null;
  tmdbUrl: string | null;
  // How far the media server's download is, when one runs.
  download?: Download | null;
  // The media server's own id for the title, once it has it.
  mediaServerId?: string | null;
  // The rest a provider may know; the details show what is there.
  tagline?: string | null;
  originalTitle?: string | null;
  status?: string | null;
  releaseDate?: string | null;
  lastAired?: string | null;
  budget?: number | null;
  revenue?: number | null;
  studios?: string[];
  collection?: { id: number; name: string } | null;
  cast?: CastMember[];
  crew?: CastMember[];
  seasonList?: SeasonSummary[];
  episodes?: number | null;
};

export type BrowseQuery = {
  mediaType: MediaType;
  sort: BrowseSort;
  genre?: string;
  language?: string;
  decade?: number;
  year?: number;
  page: number;
};

export type BrowsePage = {
  page: number;
  totalPages: number;
  items: CatalogueTitle[];
  genres: { id: string; name: string }[];
};

export type Person = PersonDetail & {
  // Each title with the part in `match`: "als Nyles", "Regie".
  titles: (CatalogueTitle & { part: string | null })[];
};

export type Download = { progress: number; eta: string | null };

export type CatalogueHit = { title: CatalogueTitle; why: string | null };

// Where the catalogue comes from: Seerr (TMDB's data), fixtures in
// development. The Mac never talks to a provider; keys stay on the server.
export interface CatalogueProvider {
  readonly origin: DataOrigin;
  readonly name: string;
  // The pool proposals are ranked from: trending, popular, new, available.
  candidates(): Promise<CatalogueTitle[]>;
  title(ref: TitleRef): Promise<CatalogueTitle | undefined>;
  // Title, maker, cast, genre and trait, old and new alike.
  search(
    query: string,
  ): Promise<{ hits: CatalogueHit[]; credits: { id: string; name: string }[] }>;
  // Films or series a page at a time, the way a shop sorts them.
  browse(query: BrowseQuery): Promise<BrowsePage>;
  // What goes with a title, in the source's order; empty when it has none.
  related(ref: TitleRef): Promise<CatalogueTitle[]>;
  person(id: string): Promise<Person | undefined>;
}

// `known`: the media server already has, fetches or awaits the title.
export type MediaState = { known: boolean; requestId: number | null };

// Asks the media server for a title. Only the live catalogue requests; the
// fixtures never do.
export interface MediaRequester {
  state(ref: TitleRef): Promise<MediaState>;
  request(
    ref: TitleRef,
    seasons: number[] | null,
  ): Promise<{ requestId: number | null; existed: boolean }>;
}

// How much two titles share: traits count double, genres once.
export function overlap(a: CatalogueTitle, b: CatalogueTitle) {
  const traits = a.traits.filter((t) => b.traits.includes(t)).length;
  const genres = a.genres.filter((g) => b.genres.includes(g)).length;
  return traits * 2 + genres;
}
