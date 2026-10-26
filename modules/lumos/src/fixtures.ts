import type {
  Availability,
  Credit,
  MediaType,
  Score,
  Snippet,
  Trailer,
} from '@burrow/contracts';
import {
  type BrowsePage,
  type BrowseQuery,
  type CatalogueHit,
  type CatalogueProvider,
  type CatalogueTitle,
  overlap,
  type Person,
  type TitleRef,
} from './catalogue';

// Test data for development and tests, never the real catalogue: every
// response from it says `dataOrigin: 'fixture'`, the Mac shows a badge, and
// the server refuses it where a real catalogue is configured or deployed.
//
// Most titles, makers and scores are invented. Three are real, because they
// have trailer references checked on 24 October 2026: Palm Springs and The
// Holdovers (YouTube) and Sintel (a CC BY 3.0 stream of the Blender
// Foundation). Their scores and quotes are dated snapshots with a source;
// nothing else about them is made up. Ids start at 9,000,001 so they are
// never mistaken for TMDB ids, and there is no artwork: the Mac draws a
// placeholder.

const CHECKED = '2026-10-24';
const MADE = '2026-10-25';

type Seed = {
  id: number;
  type: MediaType;
  title: string;
  year: number;
  minutes?: number;
  seasons?: number;
  genres: string[];
  traits: string[];
  language: string;
  // Directors of a film, creators of a series.
  makers: string[];
  cast: string[];
  synopsis: string;
  availability: Availability;
  popularity: number;
  scores?: Score[];
  snippets?: Snippet[];
  trailer?: Trailer;
  tmdbUrl?: string;
};

const slug = (name: string) =>
  name
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');

const testScores = (imdb: number, votes: number, tmdb?: number): Score[] => [
  {
    source: 'IMDb (test)',
    label: null,
    value: imdb,
    scale: 'ten',
    votes,
    votesAtLeast: false,
    asOf: MADE,
    url: null,
  },
  ...(tmdb === undefined
    ? []
    : [
        {
          source: 'TMDB (test)',
          label: null,
          value: tmdb,
          scale: 'ten' as const,
          votes: Math.round(votes / 9),
          votesAtLeast: false,
          asOf: MADE,
          url: null,
        },
      ]),
];

const SEEDS: Seed[] = [
  {
    id: 9_000_001,
    type: 'movie',
    title: 'Palm Springs',
    year: 2020,
    minutes: 90,
    genres: ['Komedie', 'Romantiek'],
    traits: ['Tijdlus', 'Droge humor', 'Absurd'],
    language: 'Engels',
    makers: ['Max Barbakow'],
    cast: ['Andy Samberg', 'Cristin Milioti', 'J.K. Simmons'],
    synopsis:
      'Nyles en Sarah ontmoeten elkaar op een bruiloft in Palm Springs. Wanneer Sarah net als Nyles vast komt te zitten in een tijdlus, proberen ze samen uit te zoeken wat er nog toe doet.',
    availability: 'available',
    popularity: 9.2,
    scores: [
      {
        source: 'Rotten Tomatoes',
        label: 'Critics',
        value: 95,
        scale: 'percent',
        votes: 254,
        votesAtLeast: false,
        asOf: CHECKED,
        url: 'https://www.rottentomatoes.com/m/palm_springs_2020',
      },
      {
        source: 'Rotten Tomatoes',
        label: 'Audience',
        value: 89,
        scale: 'percent',
        votes: 2500,
        votesAtLeast: true,
        asOf: CHECKED,
        url: 'https://www.rottentomatoes.com/m/palm_springs_2020',
      },
    ],
    snippets: [
      {
        source: 'Sight and Sound (BFI)',
        author: 'Thomas Flew',
        url: 'https://www.bfi.org.uk/sight-and-sound/reviews/palm-springs-2020-max-barbakow-andy-samberg-cristi-miliotti-groundhog-day-infinite-time-loop-meet-cute',
        quote: 'Miliotti is at her best in these goofy, lighthearted moments',
        language: 'en',
        checkedAt: CHECKED,
      },
      {
        source: 'RogerEbert.com',
        author: 'Sheila O’Malley',
        url: 'https://www.rogerebert.com/reviews/palm-springs-movie-review-2020',
        quote:
          'the film strikes an unexpectedly tender almost bittersweet chord',
        language: 'en',
        checkedAt: CHECKED,
      },
    ],
    trailer: {
      provider: 'youtube',
      key: 'pI5w1I6IX40',
      url: 'https://www.youtube.com/watch?v=pI5w1I6IX40',
      publisher: 'Amazon Prime Video UK & IE',
      language: 'en',
      checkedAt: CHECKED,
    },
    tmdbUrl: 'https://www.themoviedb.org/movie/587792',
  },
  {
    id: 9_000_002,
    type: 'movie',
    title: 'The Holdovers',
    year: 2023,
    minutes: 133,
    genres: ['Komedie', 'Drama'],
    traits: ['Kerst', 'Rustig tempo', 'Melancholisch'],
    language: 'Engels',
    makers: ['Alexander Payne'],
    cast: ['Paul Giamatti', 'Da’Vine Joy Randolph', 'Dominic Sessa'],
    synopsis:
      'Een strenge leraar moet tijdens de kerstvakantie toezicht houden op een leerling die niet naar huis kan. Samen met de schoolkok vormen ze een onwaarschijnlijk gezelschap.',
    availability: 'not-requested',
    popularity: 8.6,
    trailer: {
      provider: 'youtube',
      key: 'xp-AvgbyXRU',
      url: 'https://www.youtube.com/watch?v=xp-AvgbyXRU',
      publisher: 'Universal Pictures Canada',
      language: 'en',
      checkedAt: CHECKED,
    },
    tmdbUrl: 'https://www.themoviedb.org/movie/840430',
  },
  {
    id: 9_000_003,
    type: 'movie',
    title: 'Sintel',
    year: 2010,
    minutes: 15,
    genres: ['Animatie', 'Fantasy', 'Drama'],
    traits: ['Avontuur', 'Draken', 'Melancholisch'],
    language: 'Engels',
    makers: ['Colin Levy'],
    cast: ['Halina Reijn', 'Thom Hoffman'],
    synopsis:
      'Sintel verzorgt een gewonde jonge draak. Als hij wordt meegenomen, verlaat ze haar thuis om hem te zoeken. Een onafhankelijk gemaakte animatiefilm van de Blender Foundation.',
    availability: 'not-requested',
    popularity: 5.1,
    scores: [
      {
        source: 'Rotten Tomatoes',
        label: 'Audience',
        value: 74,
        scale: 'percent',
        votes: 100,
        votesAtLeast: true,
        asOf: CHECKED,
        url: 'https://www.rottentomatoes.com/m/sintel',
      },
    ],
    snippets: [
      {
        source: 'Pop Culture Beast',
        author: null,
        url: 'https://popculturebeast.blogspot.com/2010/10/sintel-short-film-review.html',
        quote: 'The ending left me speechless.',
        language: 'en',
        checkedAt: CHECKED,
      },
    ],
    trailer: {
      provider: 'direct',
      url: 'https://download.blender.org/durian/trailer/sintel_trailer-480p.mp4',
      sourceUrl: 'https://www.youtube.com/watch?v=HOfdboHvshg',
      publisher: 'Blender Foundation',
      language: 'en',
      license: 'CC BY 3.0',
      checkedAt: CHECKED,
    },
  },
  {
    id: 9_000_011,
    type: 'movie',
    title: 'Het Laatste Licht',
    year: 2024,
    minutes: 112,
    genres: ['Drama'],
    traits: ['Melancholisch', 'Rustig tempo', 'Familie'],
    language: 'Nederlands',
    makers: ['Mira Oosterbeek'],
    cast: ['Joris Hamaker', 'Sanne Dijkhuis', 'Pieter Molenaar'],
    synopsis:
      'Een vuurtorenwachter op een Waddeneiland krijgt een laatste winter voordat de toren automatisch wordt. Zijn dochter komt terug om hem te helpen met de verhuizing.',
    availability: 'available',
    popularity: 7.4,
    scores: testScores(7.3, 8_412, 7.1),
  },
  {
    id: 9_000_012,
    type: 'movie',
    title: 'Northbound',
    year: 2025,
    minutes: 104,
    genres: ['Thriller'],
    traits: ['Hoog tempo', 'Mysterie', 'Reis'],
    language: 'Engels',
    makers: ['Tobias Krell'],
    cast: ['Yara Moreau', 'Casper Wendt'],
    synopsis:
      'Een nachttrein naar Narvik stopt midden in de sneeuw. Eén passagier blijkt niet op de lijst te staan, en de conducteur weet waarom.',
    availability: 'not-requested',
    popularity: 8.1,
    scores: testScores(6.9, 21_330, 6.8),
  },
  {
    id: 9_000_013,
    type: 'movie',
    title: 'Zeven Zomers',
    year: 2019,
    minutes: 98,
    genres: ['Romantiek', 'Komedie'],
    traits: ['Warm', 'Droge humor'],
    language: 'Nederlands',
    makers: ['Lena Vos'],
    cast: ['Sanne Dijkhuis', 'Ruben Stal'],
    synopsis:
      'Twee mensen ontmoeten elkaar zeven zomers achter elkaar op dezelfde camping, steeds met iemand anders.',
    availability: 'available',
    popularity: 6.2,
    scores: testScores(6.6, 3_904),
  },
  {
    id: 9_000_014,
    type: 'movie',
    title: 'The Quiet Orbit',
    year: 2023,
    minutes: 127,
    genres: ['Sciencefiction', 'Drama'],
    traits: ['Rustig tempo', 'Melancholisch', 'Ruimte'],
    language: 'Engels',
    makers: ['Elif Kaya'],
    cast: ['Felix Brandt', 'Noor el Idrissi'],
    synopsis:
      'Een onderhoudsmonteur blijft als laatste achter op een ruimtestation dat wordt afgebouwd, en begint berichten te ontvangen van zichzelf.',
    availability: 'available',
    popularity: 7.9,
    scores: testScores(7.6, 45_120, 7.4),
  },
  {
    id: 9_000_015,
    type: 'movie',
    title: 'Kopje Koffie',
    year: 2022,
    minutes: 89,
    genres: ['Komedie'],
    traits: ['Droge humor', 'Dagelijks leven'],
    language: 'Nederlands',
    makers: ['Hugo Verbeek'],
    cast: ['Pieter Molenaar', 'Ilse Kramer'],
    synopsis:
      'Een koffiezaak in Utrecht krijgt een nieuwe buurman: een tweede koffiezaak. De eigenaren besluiten elkaar met vriendelijkheid kapot te maken.',
    availability: 'not-requested',
    popularity: 5.8,
  },
  {
    id: 9_000_016,
    type: 'movie',
    title: 'Midnight at the Ferry',
    year: 1958,
    minutes: 94,
    genres: ['Misdaad', 'Thriller'],
    traits: ['Whodunit', 'Mysterie', 'Zwart-wit'],
    language: 'Engels',
    makers: ['Arthur Pelling'],
    cast: ['Margaret Holloway', 'Desmond Clarke'],
    synopsis:
      'Op de laatste veerboot van de avond verdwijnt een juwelier. Een gepensioneerde inspecteur heeft tot de aankomst om uit te vinden wie hem overboord zette.',
    availability: 'not-requested',
    popularity: 4.9,
    scores: testScores(7.1, 2_210),
  },
  {
    id: 9_000_017,
    type: 'movie',
    title: 'Station Zuid',
    year: 1973,
    minutes: 101,
    genres: ['Drama', 'Misdaad'],
    traits: ['Politiek', 'Rustig tempo'],
    language: 'Nederlands',
    makers: ['Wim Doorduin'],
    cast: ['Hendrik Baas', 'Corrie Lindeman'],
    synopsis:
      'Een stationschef ziet hoe zijn station het middelpunt wordt van een staking die het hele land stillegt.',
    availability: 'available',
    popularity: 4.2,
  },
  {
    id: 9_000_018,
    type: 'movie',
    title: 'Paper Moons',
    year: 1979,
    minutes: 96,
    genres: ['Komedie', 'Romantiek'],
    traits: ['Warm', 'Absurd'],
    language: 'Engels',
    makers: ['Arthur Pelling'],
    cast: ['Desmond Clarke', 'Rosalind Fairweather'],
    synopsis:
      'Een decorbouwer en een souffleuse ontdekken dat het toneelstuk waaraan ze werken over hun eigen leven gaat.',
    availability: 'not-requested',
    popularity: 4.6,
    scores: testScores(6.8, 1_540),
  },
  {
    id: 9_000_019,
    type: 'movie',
    title: 'Loop of Tuesdays',
    year: 2026,
    minutes: 95,
    genres: ['Komedie', 'Sciencefiction'],
    traits: ['Tijdlus', 'Absurd', 'Droge humor'],
    language: 'Engels',
    makers: ['Elif Kaya'],
    cast: ['Ruben Stal', 'Yara Moreau'],
    synopsis:
      'Een belastingadviseur beleeft elke dinsdag opnieuw, maar alleen de dinsdagen. De rest van de week loopt gewoon door.',
    availability: 'waiting-for-release',
    popularity: 8.4,
  },
  {
    id: 9_000_020,
    type: 'movie',
    title: 'Wintergasten',
    year: 2021,
    minutes: 118,
    genres: ['Drama', 'Komedie'],
    traits: ['Kerst', 'Familie', 'Warm'],
    language: 'Nederlands',
    makers: ['Mira Oosterbeek'],
    cast: ['Ilse Kramer', 'Joris Hamaker'],
    synopsis:
      'Drie zussen vieren kerst in het huis van hun overleden moeder, dat na de feestdagen verkocht wordt.',
    availability: 'available',
    popularity: 6.7,
    scores: testScores(7.0, 5_022, 6.9),
  },
  {
    id: 9_000_021,
    type: 'movie',
    title: 'The Cartographer’s Daughter',
    year: 2024,
    minutes: 131,
    genres: ['Avontuur', 'Fantasy'],
    traits: ['Avontuur', 'Reis', 'Draken'],
    language: 'Engels',
    makers: ['Tobias Krell'],
    cast: ['Noor el Idrissi', 'Casper Wendt'],
    synopsis:
      'De dochter van een kaartenmaker volgt de laatste, onafgemaakte kaart van haar vader naar een eiland dat op geen enkele andere kaart staat.',
    availability: 'not-requested',
    popularity: 7.2,
    scores: testScores(6.5, 12_870, 6.7),
  },
  {
    id: 9_000_022,
    type: 'movie',
    title: 'Ruis',
    year: 2025,
    minutes: 108,
    genres: ['Thriller', 'Sciencefiction'],
    traits: ['Spionage', 'Hoog tempo', 'Politiek'],
    language: 'Nederlands',
    makers: ['Hugo Verbeek'],
    cast: ['Felix Brandt', 'Sanne Dijkhuis'],
    synopsis:
      'Een geluidstechnicus bij een radiostation hoort in de ruis van een oude zender een gesprek dat nog moet plaatsvinden.',
    availability: 'requested',
    popularity: 7.7,
  },
  {
    id: 9_000_023,
    type: 'movie',
    title: 'Lantern Keepers',
    year: 2020,
    minutes: 102,
    genres: ['Animatie', 'Fantasy'],
    traits: ['Avontuur', 'Familie', 'Warm'],
    language: 'Engels',
    makers: ['Lena Vos'],
    cast: ['Rosalind Fairweather', 'Ruben Stal'],
    synopsis:
      'In een stad waar het nooit dag wordt, zorgen twee kinderen voor de lantaarns, tot er één uitgaat die niet meer aan wil.',
    availability: 'available',
    popularity: 6.4,
    scores: testScores(7.2, 9_806, 7.5),
  },
  {
    id: 9_000_024,
    type: 'movie',
    title: 'Wilde Wadden',
    year: 2023,
    minutes: 84,
    genres: ['Documentaire'],
    traits: ['Natuur', 'Rustig tempo'],
    language: 'Nederlands',
    makers: ['Bastiaan Rook'],
    cast: [],
    synopsis:
      'Een jaar op het wad, van de eerste zeehondjes tot de stormen van november, gefilmd vanaf één kwelder.',
    availability: 'available',
    popularity: 4.4,
  },
  {
    id: 9_000_025,
    type: 'movie',
    title: 'A Room in Lisbon',
    year: 2017,
    minutes: 109,
    genres: ['Romantiek', 'Drama'],
    traits: ['Melancholisch', 'Reis'],
    language: 'Portugees',
    makers: ['Inês Carvalho'],
    cast: ['Yara Moreau', 'Felix Brandt'],
    synopsis:
      'Twee vreemden huren per ongeluk dezelfde kamer in Lissabon voor een week, en geen van beiden wil weg.',
    availability: 'not-requested',
    popularity: 5.3,
    scores: testScores(6.9, 4_388),
  },
  {
    id: 9_000_026,
    type: 'movie',
    title: 'Overtime',
    year: 2024,
    minutes: 99,
    genres: ['Komedie'],
    traits: ['Absurd', 'Hoog tempo'],
    language: 'Engels',
    makers: ['Casper Wendt'],
    cast: ['Ruben Stal', 'Ilse Kramer'],
    synopsis:
      'Een kantoor dat nooit dichtgaat, een team dat nooit naar huis mag, en een stagiair die ontdekt waarom.',
    availability: 'downloading',
    popularity: 6.9,
  },
  {
    id: 9_000_031,
    type: 'tv',
    title: 'Bakkerij Bloem',
    year: 2023,
    seasons: 2,
    genres: ['Komedie'],
    traits: ['Warm', 'Dagelijks leven', 'Familie'],
    language: 'Nederlands',
    makers: ['Lena Vos'],
    cast: ['Pieter Molenaar', 'Corrie Lindeman'],
    synopsis:
      'Een familiebakkerij in Deventer, drie generaties achter één toonbank en een kleinzoon die alles anders wil.',
    availability: 'available',
    popularity: 7.0,
    scores: testScores(7.4, 6_118),
  },
  {
    id: 9_000_032,
    type: 'tv',
    title: 'Signal Hill',
    year: 2024,
    seasons: 1,
    genres: ['Thriller', 'Misdaad'],
    traits: ['Whodunit', 'Mysterie'],
    language: 'Engels',
    makers: ['Tobias Krell'],
    cast: ['Margaret Holloway', 'Felix Brandt'],
    synopsis:
      'Een dorp aan de Ierse kust, een verdwenen radioamateur en een detective die eigenlijk op vakantie was.',
    availability: 'not-requested',
    popularity: 7.8,
    scores: testScores(7.9, 31_402, 7.6),
  },
  {
    id: 9_000_033,
    type: 'tv',
    title: 'Het Archief',
    year: 2025,
    seasons: 1,
    genres: ['Sciencefiction', 'Thriller'],
    traits: ['Mysterie', 'Politiek', 'Tijdlus'],
    language: 'Nederlands',
    makers: ['Elif Kaya'],
    cast: ['Noor el Idrissi', 'Hendrik Baas'],
    synopsis:
      'Een archivaris vindt dossiers over gebeurtenissen die nog niet hebben plaatsgevonden, in haar eigen handschrift.',
    availability: 'partially-available',
    popularity: 8.3,
  },
  {
    id: 9_000_034,
    type: 'tv',
    title: 'Coastline',
    year: 2022,
    seasons: 3,
    genres: ['Drama'],
    traits: ['Familie', 'Melancholisch', 'Rustig tempo'],
    language: 'Engels',
    makers: ['Mira Oosterbeek'],
    cast: ['Joris Hamaker', 'Rosalind Fairweather'],
    synopsis:
      'Een vissersfamilie in Cornwall houdt het bedrijf draaiende terwijl de zee en de bank allebei terugkomen.',
    availability: 'available',
    popularity: 6.6,
    scores: testScores(8.0, 18_250, 7.8),
  },
  {
    id: 9_000_035,
    type: 'tv',
    title: 'Dispatch',
    year: 2026,
    seasons: 1,
    genres: ['Misdaad', 'Drama'],
    traits: ['Hoog tempo', 'Politiek'],
    language: 'Engels',
    makers: ['Casper Wendt'],
    cast: ['Yara Moreau', 'Desmond Clarke'],
    synopsis:
      'Eén nacht op de meldkamer van een grote stad, verteld vanaf de koptelefoons van vier centralisten.',
    availability: 'not-requested',
    popularity: 7.5,
  },
];

const credits = (seed: Seed): Credit[] => [
  ...seed.makers.map((name) => ({
    id: `fx-${slug(name)}`,
    name,
    role: seed.type === 'tv' ? ('creator' as const) : ('director' as const),
  })),
  ...seed.cast.map((name) => ({
    id: `fx-${slug(name)}`,
    name,
    role: 'cast' as const,
  })),
];

const toTitle = (seed: Seed): CatalogueTitle => ({
  mediaType: seed.type,
  tmdbId: seed.id,
  title: seed.title,
  year: seed.year,
  runtimeMinutes: seed.minutes ?? null,
  seasons: seed.seasons ?? null,
  genres: seed.genres,
  traits: seed.traits,
  language: seed.language,
  poster: null,
  backdrop: null,
  availability: seed.availability,
  popularity: seed.popularity,
  synopsis: seed.synopsis,
  synopsisLanguage: 'nl',
  credits: credits(seed),
  scores: seed.scores ?? [],
  snippets: seed.snippets ?? [],
  trailer: seed.trailer ?? null,
  stills: [],
  stillsCredit: null,
  tmdbUrl: seed.tmdbUrl ?? null,
});

const fold = (text: string) =>
  text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase();

const ROLE = { director: 'Regie', creator: 'Maker', cast: 'Cast' } as const;

export class FixtureCatalogue implements CatalogueProvider {
  readonly origin = 'fixture' as const;
  readonly name = 'Testgegevens';
  private readonly titles = SEEDS.map(toTitle);

  async candidates() {
    return this.titles;
  }

  async title(ref: TitleRef) {
    return this.titles.find(
      (t) => t.mediaType === ref.mediaType && t.tmdbId === ref.tmdbId,
    );
  }

  async search(query: string) {
    const q = fold(query.trim());
    const hits: CatalogueHit[] = [];
    const found = new Map<string, string>();
    if (!q) return { hits, credits: [] };
    for (const title of this.titles) {
      if (fold(title.title).includes(q)) {
        hits.push({ title, why: null });
        continue;
      }
      const credit = title.credits.find((c) => fold(c.name).includes(q));
      const genre = title.genres.find((g) => fold(g).includes(q));
      const trait = title.traits.find((t) => fold(t).includes(q));
      const why = credit
        ? `${ROLE[credit.role]}: ${credit.name}`
        : genre
          ? `Genre: ${genre}`
          : trait
            ? `Kenmerk: ${trait}`
            : String(title.year) === q
              ? `Jaar: ${title.year}`
              : undefined;
      if (why) hits.push({ title, why });
    }
    for (const title of this.titles) {
      for (const c of title.credits) {
        if (fold(c.name).includes(q)) found.set(c.id, c.name);
      }
    }
    // Title matches first, then by popularity.
    hits.sort(
      (a, b) =>
        Number(a.why !== null) - Number(b.why !== null) ||
        b.title.popularity - a.title.popularity,
    );
    return {
      hits,
      credits: [...found].map(([id, name]) => ({ id, name })),
    };
  }

  async person(id: string): Promise<Person | undefined> {
    const titles = this.titles.filter((t) =>
      t.credits.some((c) => c.id === id),
    );
    const name = titles[0]?.credits.find((c) => c.id === id)?.name;
    if (!name) return undefined;
    const part = (t: CatalogueTitle) => {
      const role = t.credits.find((c) => c.id === id)?.role;
      return role === 'cast' ? 'als zichzelf' : role ? ROLE[role] : null;
    };
    return {
      id,
      name,
      photo: null,
      biography: null,
      birthday: null,
      deathday: null,
      placeOfBirth: null,
      known: titles.some((t) =>
        t.credits.some((c) => c.id === id && c.role !== 'cast'),
      )
        ? 'Directing'
        : 'Acting',
      titles: titles
        .toSorted((a, b) => (b.year ?? 0) - (a.year ?? 0))
        .map((t) => ({ ...t, part: part(t) })),
    };
  }

  // What goes with a title: the most shared traits and genres first.
  async related(ref: TitleRef) {
    const source = await this.title(ref);
    if (!source) return [];
    return this.titles
      .filter((t) => t !== source && overlap(source, t) > 0)
      .toSorted(
        (a, b) =>
          overlap(source, b) - overlap(source, a) ||
          b.popularity - a.popularity,
      )
      .slice(0, 12);
  }

  // The fixtures as a shop would sort them; one page of twelve.
  async browse(q: BrowseQuery): Promise<BrowsePage> {
    const genres = [
      ...new Set(
        this.titles
          .filter((t) => t.mediaType === q.mediaType)
          .flatMap((t) => t.genres),
      ),
    ]
      .toSorted()
      .map((name) => ({ id: name, name }));
    const thisYear = Math.max(...this.titles.map((t) => t.year ?? 0));
    let items = this.titles.filter(
      (t) =>
        t.mediaType === q.mediaType &&
        (!q.genre || t.genres.includes(q.genre)) &&
        (!q.language ||
          (q.language === 'nl') === (t.language === 'Nederlands')) &&
        (!q.decade ||
          ((t.year ?? 0) >= q.decade && (t.year ?? 0) < q.decade + 10)) &&
        (!q.year || t.year === q.year),
    );
    const score = (t: CatalogueTitle) => t.scores[0]?.value ?? 0;
    switch (q.sort) {
      case 'popular':
      case 'trending':
        items = items.toSorted((a, b) => b.popularity - a.popularity);
        break;
      case 'new':
        items = items
          .filter((t) => (t.year ?? 0) <= thisYear)
          .toSorted((a, b) => (b.year ?? 0) - (a.year ?? 0));
        break;
      case 'upcoming':
        items = items.filter((t) => t.availability === 'waiting-for-release');
        break;
      case 'top':
      case 'gems':
        items = items
          .filter((t) => score(t) > 0)
          .toSorted((a, b) => score(b) - score(a));
        break;
    }
    const size = 12;
    const totalPages = Math.max(1, Math.ceil(items.length / size));
    return {
      page: q.page,
      totalPages,
      items: items.slice((q.page - 1) * size, q.page * size),
      genres,
    };
  }
}
