import type {
  Availability,
  Credit,
  DataOrigin,
  MediaType,
  Score,
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
};

export type CatalogueHit = { title: CatalogueTitle; why: string | null };

// Where the catalogue comes from: Seerr with TMDB later, fixtures in
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
  credit(
    id: string,
  ): Promise<
    | { credit: { id: string; name: string }; titles: CatalogueTitle[] }
    | undefined
  >;
}

// How much two titles share: traits count double, genres once.
export function overlap(a: CatalogueTitle, b: CatalogueTitle) {
  const traits = a.traits.filter((t) => b.traits.includes(t)).length;
  const genres = a.genres.filter((g) => b.genres.includes(g)).length;
  return traits * 2 + genres;
}
