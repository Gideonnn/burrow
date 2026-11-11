import {
  type BrowseQuery,
  type BrowseResponse,
  type BrowseSort,
  type CreateVerdictRequest,
  type CreditResponse,
  type DataOrigin,
  type ListEntry,
  type ListScope,
  type LumosStatus,
  type ManageItem,
  type ManageResponse,
  type MediaType,
  type SeenVerdicts,
  passKinds,
  type PlayResponse,
  type RowsResponse,
  type TitleDetail,
  type TitleRow,
  type TitleSummary,
  type Verdict,
  type VerdictRef,
  type WatchResponse,
} from '@burrow/contracts';
import { type Access, listPeople, type Platform } from '@burrow/platform';
import { and, desc, eq, isNull } from 'drizzle-orm';
import {
  bareTitle,
  type CatalogueProvider,
  type CatalogueTitle,
  type Holding,
  type MediaRequester,
  overlap,
  parseRefKey,
  refKey,
  type TitleRef,
} from './catalogue';
import {
  groupOf,
  insertVerdict,
  isOwner,
  isPass,
  noEffects,
  recordChange,
  removeFromList,
  scopeOf,
  undoChange,
  undoVerdicts,
} from './changes';
import {
  type Going,
  type JellyfinPlayer,
  LibraryFacts,
  type TitleFacts,
} from './jellyfin';
import {
  type Context,
  listedIn,
  matchOf,
  mulberry,
  type Pool,
  rank,
  resumeLine,
  seedOf,
  type VerdictRow,
} from './ranking';
import { LumosRequests, requestState } from './requests';
import { lumosChanges, lumosListItems, lumosVerdicts } from './schema';

export const MODULE = 'lumos';

// "Ruimte maken" proposes titles larger than this.
const SPACE_CANDIDATE_BYTES = 25_000_000_000;

export class LumosError extends Error {}
// No catalogue is connected; lists still work.
export class NotConnected extends LumosError {
  constructor() {
    super('Lumos is niet gekoppeld aan een catalogus');
  }
}
// No Jellyfin is connected; everything but watching works.
export class NoPlayer extends LumosError {
  constructor() {
    super('Lumos is niet gekoppeld aan Jellyfin');
  }
}

const verdictRef = (row: VerdictRow): VerdictRef => ({
  id: row.id,
  kind: row.kind,
  reason: row.reason,
});

const onServer = (f: TitleFacts | null) =>
  f ? { sizeBytes: f.sizeBytes, media: f.media, watched: f.watched } : null;

// Lumos: a catalogue to browse with lists and verdicts of its own. The
// household's list and verdicts belong to everyone in it; a personal list is
// its owner's and nobody else ever sees it, like a recording in Pensieve.
// With the live catalogue, a title put on a list is requested from the media
// server (see requests.ts); the fixtures never request anything.
export class Lumos {
  readonly requests?: LumosRequests;

  private readonly manager?: MediaRequester;

  constructor(
    private readonly platform: Platform,
    private readonly catalogue?: CatalogueProvider,
    requester?: MediaRequester,
    private readonly player?: JellyfinPlayer,
  ) {
    if (requester && catalogue?.origin === 'live') {
      this.requests = new LumosRequests(platform, requester);
      this.manager = requester;
    }
  }

  private get db() {
    return this.platform.db;
  }

  // Fixture rows stay apart from real ones, also after switching provider.
  get origin(): DataOrigin {
    return this.catalogue?.origin ?? 'live';
  }

  private need() {
    if (!this.catalogue) throw new NotConnected();
    return this.catalogue;
  }

  private needPlayer() {
    if (!this.player) throw new NoPlayer();
    return this.player;
  }

  // What Jellyfin knows of the library; empty when it is not connected or
  // does not answer, so a page never waits on it to fail.
  private async libraryFacts(): Promise<LibraryFacts> {
    return (
      (await this.player?.library().catch(() => undefined)) ??
      new LibraryFacts()
    );
  }

  // Only what was watched matters to the proposals; without the household
  // account there is nothing to read for them.
  private watchedFacts() {
    return this.player?.readsUser
      ? this.libraryFacts()
      : Promise.resolve(new LibraryFacts());
  }

  // Played to the end by the household account.
  private playedIn(facts: LibraryFacts) {
    return (t: CatalogueTitle) => facts.get(t)?.watched?.played === true;
  }

  // "Al gezien" verdicts: the household's and the person's own.
  private seenVerdicts(access: Access) {
    const keys = (person: string | null) =>
      new Set(
        this.activeVerdicts(person)
          .filter((v) => v.kind === 'seen')
          .map(refKey),
      );
    const together = keys(null);
    const me = keys(access.personId);
    return (t: TitleRef): SeenVerdicts => ({
      together: together.has(refKey(t)),
      me: me.has(refKey(t)),
    });
  }

  // On anyone's list, the shared one or a person's own.
  private listedAnywhere() {
    return new Set(
      this.db
        .select({
          mediaType: lumosListItems.mediaType,
          tmdbId: lumosListItems.tmdbId,
        })
        .from(lumosListItems)
        .where(
          and(
            eq(lumosListItems.origin, this.origin),
            isNull(lumosListItems.removedAt),
          ),
        )
        .all()
        .map(refKey),
    );
  }

  status(): LumosStatus {
    return {
      dataOrigin: this.catalogue?.origin ?? null,
      catalogue: this.catalogue?.name ?? null,
      requests: Boolean(this.requests),
      watch: Boolean(this.player),
    };
  }

  // --- watching ------------------------------------------------------------

  // Where a title can be watched: its page for this machine, and the
  // screens with Jellyfin open. The library is asked itself; the
  // catalogue's "available" is not taken on trust.
  async watch(ref: TitleRef): Promise<WatchResponse> {
    const player = this.needPlayer();
    const t = await this.known(ref);
    const [item, screens] = await Promise.all([
      player.item(t),
      player.screens(),
    ]);
    const episode = item
      ? await player.episode(item, screens[0]?.userId)
      : null;
    const answer: WatchResponse = {
      web: item ? await player.webUrl(item) : null,
      episode: episode
        ? {
            season: episode.season,
            number: episode.number,
            title: episode.title,
          }
        : null,
      screens: screens.map(({ userId: _user, ...screen }) => screen),
    };
    if (player.readsUser) {
      const facts = await player.facts(t).catch(() => null);
      answer.resume = facts?.watched?.resume ?? null;
    }
    return answer;
  }

  async play(ref: TitleRef, deviceId: string): Promise<PlayResponse> {
    const player = this.needPlayer();
    const t = await this.known(ref);
    const item = await player.item(t);
    if (!item) throw new LumosError('Jellyfin heeft deze titel niet');
    return player.play(deviceId, item);
  }

  private owner(access: Access, scope: ListScope) {
    return scope === 'shared' ? null : access.personId;
  }

  // --- reading -------------------------------------------------------------

  private context(access: Access, scope: ListScope): Context {
    const items = this.db
      .select({
        ownerId: lumosListItems.ownerId,
        mediaType: lumosListItems.mediaType,
        tmdbId: lumosListItems.tmdbId,
      })
      .from(lumosListItems)
      .where(
        and(
          eq(lumosListItems.origin, this.origin),
          isNull(lumosListItems.removedAt),
        ),
      )
      .all();
    const shared = new Set<string>();
    const mine = new Set<string>();
    for (const item of items) {
      if (item.ownerId === null) shared.add(refKey(item));
      else if (item.ownerId === access.personId) mine.add(refKey(item));
    }
    const pass = new Map<string, VerdictRow>();
    const taste = new Map<string, VerdictRow>();
    for (const row of this.activeVerdicts(this.owner(access, scope))) {
      (isPass(row.kind) ? pass : taste).set(refKey(row), row);
    }
    const requests = this.requests?.all() ?? new Map();
    return { scope, shared, mine, pass, taste, requests };
  }

  private activeVerdicts(person: string | null) {
    return this.db
      .select()
      .from(lumosVerdicts)
      .where(
        and(
          isOwner(lumosVerdicts.personId, person),
          eq(lumosVerdicts.origin, this.origin),
          isNull(lumosVerdicts.undoneAt),
        ),
      )
      .orderBy(desc(lumosVerdicts.createdAt))
      .all();
  }

  private summary(
    t: CatalogueTitle,
    ctx: Context,
    match: string | null = null,
  ): TitleSummary {
    const key = refKey(t);
    const pass = ctx.pass.get(key);
    const taste = ctx.taste.get(key);
    return {
      mediaType: t.mediaType,
      tmdbId: t.tmdbId,
      title: t.title,
      year: t.year,
      runtimeMinutes: t.runtimeMinutes,
      seasons: t.seasons,
      genres: t.genres,
      traits: t.traits,
      language: t.language,
      poster: t.poster,
      backdrop: t.backdrop,
      availability: this.availability(t, ctx),
      hasTrailer: t.trailer !== null,
      onList: listedIn(ctx).has(key),
      onShared: ctx.shared.has(key),
      onMine: ctx.mine.has(key),
      pass: pass ? verdictRef(pass) : null,
      taste: taste ? verdictRef(taste) : null,
      match,
    };
  }

  // Seerr's status lags a fresh request by a cache period.
  private availability(t: CatalogueTitle, ctx: Context) {
    const request = ctx.requests.get(refKey(t));
    if (
      t.availability === 'not-requested' &&
      request &&
      ['pending', 'sent', 'exists'].includes(request.status)
    ) {
      return 'requested' as const;
    }
    return t.availability;
  }

  // List entries the provider's pool does not hold, so the list rows are
  // complete with the live catalogue too.
  private async withListed(all: CatalogueTitle[], ctx: Context) {
    const keys = new Set(all.map(refKey));
    const missing = [...new Set([...ctx.shared, ...ctx.mine])].filter(
      (k) => !keys.has(k),
    );
    const extra = await Promise.all(
      missing.map((k) =>
        this.catalogue?.title(parseRefKey(k)).catch(() => undefined),
      ),
    );
    return [
      ...all,
      ...extra.flatMap((t) => (t ? [{ ...t, popularity: 0 }] : [])),
    ];
  }

  async rows(access: Access, scope: ListScope, type?: MediaType) {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const [candidates, facts, going] = await Promise.all([
      catalogue.candidates(),
      this.watchedFacts(),
      this.player?.continueWatching().catch(() => []) ?? [],
    ]);
    const all = await this.withListed(candidates, ctx);
    const pool = new Map(all.map((t) => [refKey(t), t]));
    // Seen together on the TV hides a title from the proposals, like "seen".
    const played = this.playedIn(facts);
    const watched = all.filter(played);
    const ranked = all
      .filter((t) => !ctx.pass.has(refKey(t)) && !played(t))
      .map((t) => ({ t, score: rank(t, ctx, pool, watched) }))
      .sort((a, b) => b.score - a.score)
      .map(({ t }) => t);
    const card = (t: CatalogueTitle) =>
      this.summary(t, ctx, matchOf(t, ctx, pool));
    const together = scope === 'shared';
    const onlyMine = (t: CatalogueTitle) =>
      together && ctx.mine.has(refKey(t)) && !ctx.shared.has(refKey(t));
    const list = all
      .filter((t) => listedIn(ctx).has(refKey(t)))
      .sort((a, b) => b.popularity - a.popularity);
    const seed = seedOf(ctx, pool, list, ranked);
    const newest = Math.max(...all.map((t) => t.year ?? 0));
    const rows: TitleRow[] = [];
    if (going.length) {
      rows.push({
        key: 'continue',
        title: 'Verder kijken',
        subtitle: 'Waar jullie op de tv gebleven zijn',
        style: 'wide',
        items: await this.continueWatching(going, all, pool, ctx),
        empty: null,
      });
    }
    rows.push({
      key: 'tonight',
      title: together ? 'Voor jullie samen' : 'Voor jou',
      subtitle: together
        ? 'Gewogen op jullie lijst en bijstellingen · eigen regels, geen AI'
        : 'Gewogen op jouw lijst en bijstellingen · eigen regels, geen AI',
      style: 'wide',
      items: ranked
        .filter((t) => !onlyMine(t))
        .slice(0, 10)
        .map(card),
      empty: 'Alles is overgeslagen. Zet titels terug onder Overgeslagen.',
    });
    if (together) {
      rows.push({
        key: 'mine-not-shared',
        title: 'Op jouw lijst, nog niet samen',
        subtitle: 'Samen kijken? Zet het op onze lijst of sla het samen over',
        style: 'wide',
        items: ranked.filter(onlyMine).map(card),
        empty: null,
      });
    }
    rows.push(
      {
        key: 'list',
        title: together ? 'Onze lijst' : 'Jouw lijst',
        subtitle: list.length ? `${list.length} bewaard` : null,
        style: 'poster',
        items: list.map(card),
        empty: together
          ? 'Nog niets op onze lijst. Bewaar met J of de plusknop.'
          : 'Nog niets op jouw lijst. Bewaar met J of de plusknop.',
      },
      {
        key: 'available',
        title: 'Klaar in Jellyfin',
        subtitle: 'Staat al op de server',
        style: 'poster',
        items: ranked.filter((t) => t.availability === 'available').map(card),
        empty: null,
      },
    );
    if (seed) {
      rows.push({
        key: 'like',
        title: `Meer zoals ${seed.title}`,
        subtitle: 'Gedeelde genres en kenmerken',
        style: 'poster',
        items: ranked
          .filter((t) => refKey(t) !== refKey(seed) && overlap(seed, t) > 0)
          .sort((a, b) => overlap(seed, b) - overlap(seed, a))
          .slice(0, 12)
          .map(card),
        empty: null,
      });
    }
    rows.push(
      {
        key: 'new',
        title: 'Nieuw',
        subtitle: 'Van dit en vorig jaar',
        style: 'poster',
        items: ranked
          .filter((t) => (t.year ?? 0) >= newest - 1)
          .sort((a, b) => (b.year ?? 0) - (a.year ?? 0))
          .map(card),
        empty: null,
      },
      {
        key: 'series',
        title: 'Series',
        subtitle: null,
        style: 'poster',
        items: ranked.filter((t) => t.mediaType === 'tv').map(card),
        empty: null,
      },
      {
        key: 'later',
        title: 'Nog niet in Jellyfin',
        subtitle: this.requests
          ? 'Op de lijst zetten vraagt het aan'
          : 'Op de lijst zetten vraagt nog niets aan',
        style: 'wide',
        items: ranked.filter((t) => t.availability !== 'available').map(card),
        empty: null,
      },
    );
    return {
      dataOrigin: catalogue.origin,
      rows: rows
        .map((r) =>
          type
            ? { ...r, items: r.items.filter((t) => t.mediaType === type) }
            : r,
        )
        .filter((r) => r.items.length || r.empty),
    };
  }

  // Jellyfin's item to the catalogue: by the id Seerr knows, else TMDB's.
  private async continueWatching(
    going: Going[],
    all: CatalogueTitle[],
    pool: Pool,
    ctx: Context,
  ) {
    const plain = (id: string) => id.replaceAll('-', '').toLowerCase();
    const byItem = new Map(
      all.flatMap((t) =>
        t.mediaServerId ? [[plain(t.mediaServerId), t]] : [],
      ),
    );
    const titles = await Promise.all(
      going.slice(0, 12).map(async ({ itemId, key, resume }) => {
        let t = byItem.get(plain(itemId));
        if (!t && key) {
          const ref = parseRefKey(key);
          t =
            pool.get(refKey(ref)) ??
            (await this.need()
              .title(ref)
              .catch(() => undefined));
        }
        return t ? this.summary(t, ctx, resumeLine(resume)) : null;
      }),
    );
    return titles.filter((t): t is TitleSummary => t !== null);
  }

  // A library page: everything, passed titles included, so nothing hides.
  async titles(
    access: Access,
    scope: ListScope,
    filter: { mediaType?: 'movie' | 'tv'; available?: boolean },
  ) {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const all = await catalogue.candidates();
    const pool = new Map(all.map((t) => [refKey(t), t]));
    return {
      dataOrigin: catalogue.origin,
      items: all
        .filter(
          (t) =>
            (!filter.mediaType || t.mediaType === filter.mediaType) &&
            (!filter.available || t.availability === 'available'),
        )
        .sort((a, b) => rank(b, ctx, pool) - rank(a, ctx, pool))
        .map((t) => this.summary(t, ctx)),
    };
  }

  // Taste never applies to search: every match is shown.
  async search(
    access: Access,
    scope: ListScope,
    query: string,
    type?: MediaType,
  ) {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const known = await this.withListed(
      await catalogue.candidates().catch(() => []),
      ctx,
    );
    const { hits, credits } = await catalogue.search(query, known);
    return {
      dataOrigin: catalogue.origin,
      query,
      hits: hits
        .filter((h) => !type || h.title.mediaType === type)
        .map((h) => ({
          title: this.summary(h.title, ctx),
          why: h.why,
        })),
      credits,
    };
  }

  async detail(
    access: Access,
    scope: ListScope,
    ref: TitleRef,
  ): Promise<TitleDetail> {
    const catalogue = this.need();
    const t = await this.known(ref);
    const ctx = this.context(access, scope);
    // Without Seerr nothing is known about files, so nothing is claimed.
    const held =
      Boolean(this.manager) &&
      (t.availability === 'available' ||
        t.availability === 'partially-available');
    const [candidates, facts] = await Promise.all([
      catalogue.candidates(),
      held ? this.libraryFacts() : new LibraryFacts(),
    ]);
    const pool = new Map(candidates.map((c) => [refKey(c), c]));
    const request = ctx.requests.get(refKey(t));
    return {
      ...this.summary(t, ctx, matchOf(t, ctx, pool)),
      library: held
        ? {
            addedAt: t.addedAt ?? null,
            removable: t.removable ?? false,
            server: onServer(facts.get(t)),
          }
        : null,
      seen: this.seenVerdicts(access)(t),
      dataOrigin: catalogue.origin,
      synopsis: t.synopsis,
      synopsisLanguage: t.synopsisLanguage,
      credits: t.credits,
      scores: t.scores,
      snippets: t.snippets,
      trailer: t.trailer,
      stills: t.stills,
      stillsCredit: t.stillsCredit,
      tmdbUrl: t.tmdbUrl,
      request: request ? requestState(request) : null,
      download: t.download ?? null,
      tagline: t.tagline ?? null,
      originalTitle: t.originalTitle ?? null,
      status: t.status ?? null,
      releaseDate: t.releaseDate ?? null,
      lastAired: t.lastAired ?? null,
      budget: t.budget ?? null,
      revenue: t.revenue ?? null,
      studios: t.studios ?? [],
      collection: t.collection ?? null,
      // A provider without a cast list (the fixtures) still names its people.
      cast:
        t.cast ??
        t.credits
          .filter((c) => c.role === 'cast')
          .map((c) => ({ id: c.id, name: c.name, part: null, photo: null })),
      crew:
        t.crew ??
        t.credits
          .filter((c) => c.role !== 'cast')
          .map((c) => ({
            id: c.id,
            name: c.name,
            part: c.role === 'director' ? 'Regie' : 'Maker',
            photo: null,
          })),
      seasonList: t.seasonList ?? [],
      episodes: t.episodes ?? null,
    };
  }

  // "More like this": what the source puts next to the title, without what
  // the scope passed or wants less of.
  async similar(access: Access, scope: ListScope, ref: TitleRef) {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const related = await catalogue.related(ref);
    return {
      dataOrigin: catalogue.origin,
      items: related
        .filter((t) => {
          const key = refKey(t);
          return (
            !ctx.pass.has(key) && ctx.taste.get(key)?.kind !== 'less-like-this'
          );
        })
        .slice(0, 18)
        .map((t) => this.summary(t, ctx)),
    };
  }

  async credit(
    access: Access,
    scope: ListScope,
    id: string,
  ): Promise<CreditResponse> {
    const catalogue = this.need();
    const found = await catalogue.person(id);
    if (!found) throw new LumosError('not found');
    const ctx = this.context(access, scope);
    const { titles, ...person } = found;
    return {
      dataOrigin: catalogue.origin,
      credit: { id: person.id, name: person.name },
      person,
      titles: titles.map((t) => this.summary(t, ctx, t.part)),
    };
  }

  // Films or series a page at a time; taste never sorts a shop's shelf.
  async browse(access: Access, q: BrowseQuery): Promise<BrowseResponse> {
    const catalogue = this.need();
    const ctx = this.context(access, q.scope);
    const page = await catalogue.browse({
      mediaType: q.type,
      sort: q.sort,
      genre: q.genre,
      language: q.language,
      decade: q.decade,
      year: q.year,
      page: q.page,
    });
    return {
      dataOrigin: catalogue.origin,
      page: page.page,
      totalPages: page.totalPages,
      items: page.items.map((t) => this.summary(t, ctx)),
      genres: page.genres,
    };
  }

  // The Zoeker: rows to wander through, from what the scope likes and
  // keeps, and from the shop's shelves. `seed` reshuffles the surprises.
  async explore(
    access: Access,
    scope: ListScope,
    seed: number,
    type?: MediaType,
  ): Promise<RowsResponse> {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const [all, facts] = await Promise.all([
      catalogue.candidates(),
      this.watchedFacts(),
    ]);
    const pool = new Map(all.map((t) => [refKey(t), t]));
    const played = this.playedIn(facts);
    const keep = (t: CatalogueTitle) =>
      !ctx.pass.has(refKey(t)) && !played(t) && (!type || t.mediaType === type);
    const card = (t: CatalogueTitle, match: string | null = null) =>
      this.summary(t, ctx, match);
    const random = mulberry(seed);
    const pick = <T>(items: T[]) =>
      items.length ? items[Math.floor(random() * items.length)] : undefined;
    const rows: TitleRow[] = [];
    const row = (
      key: string,
      title: string,
      subtitle: string | null,
      items: TitleSummary[],
      style: 'wide' | 'poster' = 'poster',
    ) => {
      if (items.length)
        rows.push({ key, title, subtitle, style, items, empty: null });
    };
    const listed = listedIn(ctx);
    const liked = [...ctx.taste.values()]
      .filter((v) => v.kind === 'more-like-this')
      .map((v) => pool.get(refKey(v)))
      .filter((t): t is CatalogueTitle => Boolean(t));
    const kept = all.filter((t) => listed.has(refKey(t)));
    const seeds = [
      ...liked
        .slice(0, 2)
        .map((t) => ({ t, why: 'omdat jullie dit leuk vonden' })),
      ...[pick(kept), pick(kept)]
        .filter((t): t is CatalogueTitle => Boolean(t))
        .map((t) => ({ t, why: 'past bij jullie lijst' })),
    ].filter(
      (s, i, arr) => arr.findIndex((o) => refKey(o.t) === refKey(s.t)) === i,
    );
    const related = await Promise.all(
      seeds.map(async (s) => ({
        ...s,
        items: (await catalogue.related(s.t).catch(() => [])).filter(
          (t) => keep(t) && !listed.has(refKey(t)),
        ),
      })),
    );
    for (const { t, why, items } of related) {
      row(
        `like-${refKey(t)}`,
        `Als je ${t.title} goed vond`,
        why,
        items.slice(0, 14).map((x) => card(x, `Lijkt op ${t.title}`)),
      );
    }
    const shelf = (
      sort: BrowseSort,
      mediaType: MediaType,
      extra: Partial<BrowseQuery> = {},
    ) =>
      catalogue
        .browse({ mediaType, sort, page: 1, ...extra })
        .then((p) => p.items.filter(keep))
        .catch(() => [] as CatalogueTitle[]);
    const year = new Date().getFullYear();
    const decade = pick([1970, 1980, 1990, 2000, 2010]) ?? 1990;
    const surprisePage = 2 + Math.floor(random() * 12);
    const kind = type ?? 'movie';
    const [trending, topYear, dutch, gems, old, surprise, series] =
      await Promise.all([
        shelf('trending', kind),
        shelf('top', kind, { year }),
        shelf('popular', kind, { language: 'nl' }),
        shelf('gems', kind),
        shelf('popular', kind, { decade }),
        shelf('popular', kind, { page: surprisePage }),
        type ? Promise.resolve([] as CatalogueTitle[]) : shelf('top', 'tv'),
      ]);
    row(
      'trending',
      'Nu veel bekeken',
      'Deze week het meest bekeken',
      trending.map((t) => card(t)),
      'wide',
    );
    row(
      'top-year',
      `Best beoordeeld van ${year}`,
      'Hoogste scores met genoeg stemmen',
      topYear.map((t) => card(t)),
    );
    row(
      'series-top',
      'Series die blijven hangen',
      'De best beoordeelde series',
      series.map((t) => card(t)),
    );
    row(
      'dutch',
      kind === 'tv' ? 'Nederlandse series' : 'Nederlandse films',
      'Gemaakt in Nederland',
      dutch.map((t) => card(t)),
    );
    row(
      'gems',
      'Verborgen parels',
      'Hoog gewaardeerd, door weinig mensen gezien',
      gems.map((t) => card(t)),
    );
    row(
      `decade-${decade}`,
      `Uit de jaren ${String(decade).slice(2)}`,
      'Een greep uit het decennium',
      old.map((t) => card(t)),
    );
    row(
      'surprise',
      'Verras me',
      'Een willekeurige greep; de knop schudt opnieuw',
      surprise.map((t) => card(t)),
    );
    return { dataOrigin: catalogue.origin, rows };
  }

  private names() {
    return new Map(listPeople(this.db).map((p) => [p.id, p.name]));
  }

  // A list from its snapshots when the catalogue does not know a title (or
  // is not connected), so it never turns up empty because of the provider.
  async list(access: Access, scope: ListScope) {
    const ctx = this.context(access, scope);
    const rows = this.db
      .select()
      .from(lumosListItems)
      .where(
        and(
          isOwner(lumosListItems.ownerId, this.owner(access, scope)),
          eq(lumosListItems.origin, this.origin),
          isNull(lumosListItems.removedAt),
        ),
      )
      .orderBy(desc(lumosListItems.addedAt))
      .all();
    const names = this.names();
    const items: ListEntry[] = [];
    for (const row of rows) {
      const t = await this.catalogue?.title(row);
      items.push({
        title: t ? this.summary(t, ctx) : this.fromSnapshot(row, ctx),
        addedBy: { id: row.addedBy, name: names.get(row.addedBy) ?? '?' },
        addedAt: row.addedAt.toISOString(),
        seasons: row.seasons,
      });
    }
    return { scope, items };
  }

  private fromSnapshot(
    row: typeof lumosListItems.$inferSelect,
    ctx: Context,
  ): TitleSummary {
    const { mediaType, tmdbId, title, year, poster } = row;
    return this.summary(
      bareTitle({ mediaType, tmdbId, title, year, poster }),
      ctx,
    );
  }

  async verdicts(access: Access, scope: ListScope) {
    const ctx = this.context(access, scope);
    const names = this.names();
    const items: Verdict[] = [];
    for (const row of this.activeVerdicts(this.owner(access, scope))) {
      const t = await this.catalogue?.title(row);
      if (!t) continue;
      items.push({
        id: row.id,
        scope,
        kind: row.kind,
        reason: row.reason,
        by: { id: row.byId, name: names.get(row.byId) ?? '?' },
        createdAt: row.createdAt.toISOString(),
        title: this.summary(t, ctx),
      });
    }
    return { scope, items };
  }

  // --- changing ------------------------------------------------------------

  private async known(ref: TitleRef) {
    const t = await this.need().title(ref);
    if (!t) throw new LumosError('not found');
    return t;
  }

  private changed(access: Access, scope: ListScope) {
    const data = { type: 'lumos.changed', scope };
    if (scope === 'shared')
      this.platform.events.emit({ data, visibleTo: () => true });
    else this.platform.events.emitTo([access.personId], data);
  }

  // "Ja": on the scope's list, and no longer passed there. Adding twice, or
  // two people adding the same title to the shared list, keeps one entry.
  async addToList(
    access: Access,
    scope: ListScope,
    ref: TitleRef,
    seasons: number[] | null,
  ) {
    const t = await this.known(ref);
    const owner = this.owner(access, scope);
    const changeId = this.db.transaction((tx) => {
      const effects = noEffects();
      const added = tx
        .insert(lumosListItems)
        .values({
          ownerId: owner,
          mediaType: t.mediaType,
          tmdbId: t.tmdbId,
          origin: this.origin,
          seasons: t.mediaType === 'tv' ? seasons : null,
          title: t.title,
          year: t.year,
          poster: t.poster,
          addedBy: access.personId,
        })
        .onConflictDoNothing()
        .returning({ id: lumosListItems.id })
        .all();
      effects.listAdded.push(...added.map((r) => r.id));
      undoVerdicts(tx, this.origin, owner, t, passKinds, effects);
      // Series: only the chosen seasons, the first when none was chosen.
      this.requests?.want(
        tx,
        t,
        t.mediaType === 'tv' ? (seasons?.length ? seasons : [1]) : null,
        access.personId,
      );
      return recordChange(tx, access.personId, effects);
    });
    this.requests?.schedule();
    this.changed(access, scope);
    return { changeId };
  }

  // --- managing --------------------------------------------------------------

  private needManager() {
    if (!this.manager) throw new NotConnected();
    return this.manager;
  }

  async manage(access: Access, scope: ListScope): Promise<ManageResponse> {
    const [{ busy, library }, facts, disk] = await Promise.all([
      this.needManager().holdings(),
      this.libraryFacts(),
      this.player?.disk() ?? null,
    ]);
    const ctx = this.context(access, scope);
    const seen = this.seenVerdicts(access);
    const listed = this.listedAnywhere();
    const item = (h: Holding): ManageItem => {
      const server = onServer(facts.get(h.title));
      return {
        title: this.summary(h.title, ctx),
        download: h.download,
        addedAt: h.addedAt,
        removable: h.removable,
        server,
        seen: seen(h.title),
        spaceCandidate:
          h.removable &&
          server?.watched?.played === true &&
          (server.sizeBytes ?? 0) > SPACE_CANDIDATE_BYTES &&
          !listed.has(refKey(h.title)),
      };
    };
    return {
      dataOrigin: 'live',
      busy: busy.map(item),
      library: library.map(item),
      disk,
    };
  }

  // Deletes the files on the media server. A person's own action: the route
  // asks `admin`, which no bot can hold. Lists stay as they are; the request
  // turns dropped, so a new "Ja" asks for the title again.
  // A title that was seen (on the TV, or "Al gezien" by anyone) gets the
  // household's "Al gezien", so it is not proposed again; an unseen one
  // does not.
  async removeFromLibrary(access: Access, ref: TitleRef) {
    const manager = this.needManager();
    const [facts, t] = await Promise.all([
      this.libraryFacts(),
      this.catalogue?.title(ref).catch(() => undefined),
    ]);
    const seenInLumos = this.db
      .select({ id: lumosVerdicts.id })
      .from(lumosVerdicts)
      .where(
        and(
          eq(lumosVerdicts.mediaType, ref.mediaType),
          eq(lumosVerdicts.tmdbId, ref.tmdbId),
          eq(lumosVerdicts.origin, this.origin),
          eq(lumosVerdicts.kind, 'seen'),
          isNull(lumosVerdicts.undoneAt),
        ),
      )
      .get();
    const watched =
      facts.get(t ?? ref)?.watched?.played === true ||
      seenInLumos !== undefined;
    await manager.remove(ref);
    this.requests?.forget(ref);
    if (watched) this.markSeenTogether(access, ref);
    this.changed(access, 'shared');
    return { ok: true as const };
  }

  // The household's "Al gezien", unless it is there already. Lists stay.
  private markSeenTogether(access: Access, ref: TitleRef) {
    if (this.seenVerdicts(access)(ref).together) return;
    this.db.transaction((tx) => {
      const effects = noEffects();
      undoVerdicts(tx, this.origin, null, ref, passKinds, effects);
      insertVerdict(
        tx,
        {
          personId: null,
          byId: access.personId,
          mediaType: ref.mediaType,
          tmdbId: ref.tmdbId,
          origin: this.origin,
          kind: 'seen',
          reason: null,
        },
        effects,
      );
      recordChange(tx, access.personId, effects);
    });
  }

  retryRequest(ref: TitleRef) {
    if (!this.requests?.retry(ref)) throw new LumosError('not found');
    return { ok: true as const };
  }

  // Never deletes files or cancels a request; it only leaves the list.
  removeFromScope(access: Access, scope: ListScope, ref: TitleRef) {
    const changeId = this.db.transaction((tx) => {
      const effects = noEffects();
      removeFromList(tx, this.origin, this.owner(access, scope), ref, effects);
      return recordChange(tx, access.personId, effects);
    });
    this.changed(access, scope);
    return { changeId };
  }

  // A pass replaces the scope's earlier pass and takes the title off its
  // list; a taste verdict replaces the earlier one.
  async addVerdict(access: Access, request: CreateVerdictRequest) {
    const { scope, kind } = request;
    const t = await this.known(request);
    const person = this.owner(access, scope);
    const changeId = this.db.transaction((tx) => {
      const effects = noEffects();
      undoVerdicts(tx, this.origin, person, t, groupOf(kind), effects);
      if (isPass(kind)) removeFromList(tx, this.origin, person, t, effects);
      insertVerdict(
        tx,
        {
          personId: person,
          byId: access.personId,
          mediaType: t.mediaType,
          tmdbId: t.tmdbId,
          origin: this.origin,
          kind,
          reason: request.reason?.trim() || null,
        },
        effects,
      );
      return recordChange(tx, access.personId, effects);
    });
    this.changed(access, scope);
    return { changeId };
  }

  // "Terugzetten" or switching a taste chip off. The household's verdicts
  // are everyone's; a personal one only its person's.
  undoVerdict(access: Access, id: string) {
    const row = this.db
      .select()
      .from(lumosVerdicts)
      .where(and(eq(lumosVerdicts.id, id), isNull(lumosVerdicts.undoneAt)))
      .get();
    if (!row || (row.personId !== null && row.personId !== access.personId)) {
      throw new LumosError('not found');
    }
    const changeId = this.db.transaction((tx) => {
      tx.update(lumosVerdicts)
        .set({ undoneAt: new Date() })
        .where(eq(lumosVerdicts.id, id))
        .run();
      return recordChange(tx, access.personId, {
        ...noEffects(),
        verdictsUndone: [id],
      });
    });
    this.changed(access, scopeOf(row.personId));
    return { changeId };
  }

  // Reverses exactly what one change did; see `undoChange`.
  undo(access: Access, changeId: string) {
    const change = this.db
      .select()
      .from(lumosChanges)
      .where(
        and(
          eq(lumosChanges.id, changeId),
          eq(lumosChanges.personId, access.personId),
          isNull(lumosChanges.undoneAt),
        ),
      )
      .get();
    if (!change) throw new LumosError('not found');
    const scopes = this.db.transaction((tx) =>
      undoChange(tx, changeId, change.effects),
    );
    for (const scope of scopes) this.changed(access, scope);
    return { changeId };
  }
}
