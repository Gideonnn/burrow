import {
  type CreateVerdictRequest,
  type DataOrigin,
  type ListEntry,
  type ListScope,
  type LumosStatus,
  passKinds,
  type PlayResponse,
  type TitleDetail,
  type TitleRow,
  type TitleSummary,
  type Verdict,
  type VerdictKind,
  type VerdictRef,
  tasteKinds,
  type WatchResponse,
} from '@burrow/contracts';
import { type Access, listPeople, type Platform } from '@burrow/platform';
import { and, desc, eq, inArray, isNull } from 'drizzle-orm';
import {
  type CatalogueProvider,
  type CatalogueTitle,
  type MediaRequester,
  overlap,
  refKey,
  type TitleRef,
} from './catalogue';
import type { JellyfinPlayer } from './jellyfin';
import { LumosRequests, requestState } from './requests';
import {
  type ChangeEffects,
  lumosChanges,
  lumosListItems,
  type lumosRequests,
  lumosVerdicts,
} from './schema';

export const MODULE = 'lumos';

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

type Tx = Parameters<Parameters<Platform['db']['transaction']>[0]>[0];
type VerdictRow = typeof lumosVerdicts.$inferSelect;

const isPass = (kind: VerdictKind) =>
  (passKinds as readonly string[]).includes(kind);
const groupOf = (kind: VerdictKind) => (isPass(kind) ? passKinds : tasteKinds);

const verdictRef = (row: VerdictRow): VerdictRef => ({
  id: row.id,
  kind: row.kind,
  reason: row.reason,
});

// What one request needs to know about lists and verdicts, read once.
type Context = {
  scope: ListScope;
  shared: Set<string>;
  mine: Set<string>;
  pass: Map<string, VerdictRow>;
  taste: Map<string, VerdictRow>;
  requests: Map<string, typeof lumosRequests.$inferSelect>;
};

const noEffects = (): ChangeEffects => ({
  listAdded: [],
  listRemoved: [],
  verdictsAdded: [],
  verdictsUndone: [],
});

// Lumos: a catalogue to browse with lists and verdicts of its own. The
// household's list and verdicts belong to everyone in it; a personal list is
// its owner's and nobody else ever sees it, like a recording in Pensieve.
// With the live catalogue, a title put on a list is requested from the media
// server (see requests.ts); the fixtures never request anything.
export class Lumos {
  readonly requests?: LumosRequests;

  constructor(
    private readonly platform: Platform,
    private readonly catalogue?: CatalogueProvider,
    requester?: MediaRequester,
    private readonly player?: JellyfinPlayer,
  ) {
    if (requester && catalogue?.origin === 'live') {
      this.requests = new LumosRequests(platform, requester);
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
    const t = await this.need().title(ref);
    if (!t) throw new LumosError('not found');
    const [item, screens] = await Promise.all([
      player.item(t),
      player.screens(),
    ]);
    const episode = item
      ? await player.episode(item, screens[0]?.userId)
      : null;
    return {
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
  }

  async play(ref: TitleRef, deviceId: string): Promise<PlayResponse> {
    const player = this.needPlayer();
    const t = await this.need().title(ref);
    if (!t) throw new LumosError('not found');
    const item = await player.item(t);
    if (!item) throw new LumosError('Jellyfin heeft deze titel niet');
    return player.play(deviceId, item);
  }

  private owner(access: Access, scope: ListScope) {
    return scope === 'shared' ? null : access.personId;
  }

  private ownerIs(column: typeof lumosListItems.ownerId, owner: string | null) {
    return owner === null ? isNull(column) : eq(column, owner);
  }

  private personIs(
    column: typeof lumosVerdicts.personId,
    person: string | null,
  ) {
    return person === null ? isNull(column) : eq(column, person);
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
          this.personIs(lumosVerdicts.personId, person),
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
      onList: (ctx.scope === 'shared' ? ctx.shared : ctx.mine).has(key),
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
      missing.map((k) => {
        const [mediaType, id] = k.split(':');
        return this.catalogue
          ?.title({
            mediaType: mediaType as 'movie' | 'tv',
            tmdbId: Number(id),
          })
          .catch(() => undefined);
      }),
    );
    return [
      ...all,
      ...extra.flatMap((t) => (t ? [{ ...t, popularity: 0 }] : [])),
    ];
  }

  // The provider's popularity, the scope's list, and "more/less like this".
  // "Seen" and "not now" only hide a title; they never weigh others down.
  private rank(
    t: CatalogueTitle,
    ctx: Context,
    pool: Map<string, CatalogueTitle>,
  ) {
    const key = refKey(t);
    let score = t.popularity;
    if ((ctx.scope === 'shared' ? ctx.shared : ctx.mine).has(key)) score += 2;
    if (ctx.scope === 'shared' && ctx.mine.has(key)) score += 1;
    for (const verdict of ctx.taste.values()) {
      const source = pool.get(refKey(verdict));
      if (!source) continue;
      const sign = verdict.kind === 'more-like-this' ? 1 : -1;
      score +=
        refKey(source) === key ? sign * 4 : sign * overlap(source, t) * 1.2;
    }
    return score;
  }

  private matchOf(
    t: CatalogueTitle,
    ctx: Context,
    pool: Map<string, CatalogueTitle>,
  ) {
    const key = refKey(t);
    if (ctx.scope === 'shared' && ctx.shared.has(key)) return 'Op onze lijst';
    if (ctx.mine.has(key)) return 'Op jouw lijst';
    let best: { title: string; shared: number } | undefined;
    for (const verdict of ctx.taste.values()) {
      if (verdict.kind !== 'more-like-this') continue;
      const source = pool.get(refKey(verdict));
      if (!source || refKey(source) === key) continue;
      const shared = overlap(source, t);
      if (shared > 0 && (!best || shared > best.shared)) {
        best = { title: source.title, shared };
      }
    }
    return best ? `Lijkt op ${best.title}` : null;
  }

  async rows(access: Access, scope: ListScope) {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const all = await this.withListed(await catalogue.candidates(), ctx);
    const pool = new Map(all.map((t) => [refKey(t), t]));
    const ranked = all
      .filter((t) => !ctx.pass.has(refKey(t)))
      .map((t) => ({ t, score: this.rank(t, ctx, pool) }))
      .sort((a, b) => b.score - a.score)
      .map(({ t }) => t);
    const card = (t: CatalogueTitle) =>
      this.summary(t, ctx, this.matchOf(t, ctx, pool));
    const together = scope === 'shared';
    const onlyMine = (t: CatalogueTitle) =>
      together && ctx.mine.has(refKey(t)) && !ctx.shared.has(refKey(t));
    const listed = together ? ctx.shared : ctx.mine;
    const list = all
      .filter((t) => listed.has(refKey(t)))
      .sort((a, b) => b.popularity - a.popularity);
    const seed = this.seed(ctx, pool, list, ranked);
    const newest = Math.max(...all.map((t) => t.year ?? 0));
    const rows: TitleRow[] = [
      {
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
      },
    ];
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
      rows: rows.filter((r) => r.items.length || r.empty),
    };
  }

  // The newest "more like this", else the top of the list, else the top pick.
  private seed(
    ctx: Context,
    pool: Map<string, CatalogueTitle>,
    list: CatalogueTitle[],
    ranked: CatalogueTitle[],
  ) {
    for (const verdict of ctx.taste.values()) {
      const source = pool.get(refKey(verdict));
      if (verdict.kind === 'more-like-this' && source) return source;
    }
    return list[0] ?? ranked[0];
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
        .sort((a, b) => this.rank(b, ctx, pool) - this.rank(a, ctx, pool))
        .map((t) => this.summary(t, ctx)),
    };
  }

  // Taste never applies to search: every match is shown.
  async search(access: Access, scope: ListScope, query: string) {
    const catalogue = this.need();
    const ctx = this.context(access, scope);
    const { hits, credits } = await catalogue.search(query);
    return {
      dataOrigin: catalogue.origin,
      query,
      hits: hits.map((h) => ({
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
    const t = await catalogue.title(ref);
    if (!t) throw new LumosError('not found');
    const ctx = this.context(access, scope);
    const pool = new Map(
      (await catalogue.candidates()).map((c) => [refKey(c), c]),
    );
    return {
      ...this.summary(t, ctx, this.matchOf(t, ctx, pool)),
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
      request: (() => {
        const row = ctx.requests.get(refKey(t));
        return row ? requestState(row) : null;
      })(),
      download: t.download ?? null,
    };
  }

  // "More like this" without what the scope passed or wants less of.
  async similar(access: Access, scope: ListScope, ref: TitleRef) {
    const catalogue = this.need();
    const source = await catalogue.title(ref);
    if (!source) throw new LumosError('not found');
    const ctx = this.context(access, scope);
    const all = await catalogue.candidates();
    const pool = new Map(all.map((t) => [refKey(t), t]));
    return {
      dataOrigin: catalogue.origin,
      items: all
        .filter((t) => {
          const key = refKey(t);
          return (
            key !== refKey(source) &&
            overlap(source, t) > 0 &&
            !ctx.pass.has(key) &&
            ctx.taste.get(key)?.kind !== 'less-like-this'
          );
        })
        .sort(
          (a, b) =>
            overlap(source, b) - overlap(source, a) ||
            this.rank(b, ctx, pool) - this.rank(a, ctx, pool),
        )
        .slice(0, 8)
        .map((t) => this.summary(t, ctx)),
    };
  }

  async credit(access: Access, scope: ListScope, id: string) {
    const catalogue = this.need();
    const found = await catalogue.credit(id);
    if (!found) throw new LumosError('not found');
    const ctx = this.context(access, scope);
    return {
      dataOrigin: catalogue.origin,
      credit: found.credit,
      titles: found.titles.map((t) => this.summary(t, ctx)),
    };
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
          this.ownerIs(lumosListItems.ownerId, this.owner(access, scope)),
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
    return this.summary(
      {
        mediaType: row.mediaType,
        tmdbId: row.tmdbId,
        title: row.title,
        year: row.year,
        runtimeMinutes: null,
        seasons: null,
        genres: [],
        traits: [],
        language: null,
        poster: row.poster,
        backdrop: null,
        availability: 'not-requested',
        popularity: 0,
        synopsis: null,
        synopsisLanguage: null,
        credits: [],
        scores: [],
        snippets: [],
        trailer: null,
        stills: [],
        stillsCredit: null,
        tmdbUrl: null,
      },
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

  private record(access: Access, effects: ChangeEffects, tx: Tx) {
    return tx
      .insert(lumosChanges)
      .values({ personId: access.personId, effects })
      .returning({ id: lumosChanges.id })
      .get().id;
  }

  private changed(access: Access, scope: ListScope) {
    const data = { type: 'lumos.changed', scope };
    if (scope === 'shared')
      this.platform.events.emit({ data, visibleTo: () => true });
    else this.platform.events.emitTo([access.personId], data);
  }

  private undoActive(
    tx: Tx,
    person: string | null,
    ref: TitleRef,
    kinds: readonly VerdictKind[],
    effects: ChangeEffects,
  ) {
    const rows = tx
      .update(lumosVerdicts)
      .set({ undoneAt: new Date() })
      .where(
        and(
          this.personIs(lumosVerdicts.personId, person),
          eq(lumosVerdicts.mediaType, ref.mediaType),
          eq(lumosVerdicts.tmdbId, ref.tmdbId),
          eq(lumosVerdicts.origin, this.origin),
          inArray(lumosVerdicts.kind, [...kinds]),
          isNull(lumosVerdicts.undoneAt),
        ),
      )
      .returning({ id: lumosVerdicts.id })
      .all();
    effects.verdictsUndone.push(...rows.map((r) => r.id));
  }

  private removeFromList(
    tx: Tx,
    owner: string | null,
    ref: TitleRef,
    effects: ChangeEffects,
  ) {
    const rows = tx
      .update(lumosListItems)
      .set({ removedAt: new Date() })
      .where(
        and(
          this.ownerIs(lumosListItems.ownerId, owner),
          eq(lumosListItems.mediaType, ref.mediaType),
          eq(lumosListItems.tmdbId, ref.tmdbId),
          eq(lumosListItems.origin, this.origin),
          isNull(lumosListItems.removedAt),
        ),
      )
      .returning({ id: lumosListItems.id })
      .all();
    effects.listRemoved.push(...rows.map((r) => r.id));
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
      this.undoActive(tx, owner, t, passKinds, effects);
      // Series: only the chosen seasons, the first when none was chosen.
      this.requests?.want(
        tx,
        t,
        t.mediaType === 'tv' ? (seasons?.length ? seasons : [1]) : null,
        access.personId,
      );
      return this.record(access, effects, tx);
    });
    this.requests?.schedule();
    this.changed(access, scope);
    return { changeId };
  }

  retryRequest(ref: TitleRef) {
    if (!this.requests?.retry(ref)) throw new LumosError('not found');
    return { ok: true as const };
  }

  // Never deletes files or cancels a request; it only leaves the list.
  removeFromScope(access: Access, scope: ListScope, ref: TitleRef) {
    const changeId = this.db.transaction((tx) => {
      const effects = noEffects();
      this.removeFromList(tx, this.owner(access, scope), ref, effects);
      return this.record(access, effects, tx);
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
      this.undoActive(tx, person, t, groupOf(kind), effects);
      if (isPass(kind)) this.removeFromList(tx, person, t, effects);
      const row = tx
        .insert(lumosVerdicts)
        .values({
          personId: person,
          byId: access.personId,
          mediaType: t.mediaType,
          tmdbId: t.tmdbId,
          origin: this.origin,
          kind,
          reason: request.reason?.trim() || null,
        })
        .returning({ id: lumosVerdicts.id })
        .get();
      effects.verdictsAdded.push(row.id);
      return this.record(access, effects, tx);
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
      return this.record(access, { ...noEffects(), verdictsUndone: [id] }, tx);
    });
    this.changed(access, row.personId === null ? 'shared' : 'mine');
    return { changeId };
  }

  // Reverses exactly what one change did. A row someone else has since put
  // back (the same title re-added to the shared list) stays as it is.
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
    const { effects } = change;
    const scopes = new Set<ListScope>();
    const scopeOf = (owner: string | null): ListScope =>
      owner === null ? 'shared' : 'mine';
    this.db.transaction((tx) => {
      const now = new Date();
      for (const id of effects.listAdded) {
        const row = tx
          .update(lumosListItems)
          .set({ removedAt: now })
          .where(
            and(eq(lumosListItems.id, id), isNull(lumosListItems.removedAt)),
          )
          .returning()
          .get();
        if (row) scopes.add(scopeOf(row.ownerId));
      }
      for (const id of effects.verdictsAdded) {
        const row = tx
          .update(lumosVerdicts)
          .set({ undoneAt: now })
          .where(and(eq(lumosVerdicts.id, id), isNull(lumosVerdicts.undoneAt)))
          .returning()
          .get();
        if (row) scopes.add(scopeOf(row.personId));
      }
      for (const id of effects.listRemoved) {
        const row = tx
          .select()
          .from(lumosListItems)
          .where(eq(lumosListItems.id, id))
          .get();
        if (!row?.removedAt) continue;
        const active = tx
          .select({ id: lumosListItems.id })
          .from(lumosListItems)
          .where(
            and(
              this.ownerIs(lumosListItems.ownerId, row.ownerId),
              eq(lumosListItems.mediaType, row.mediaType),
              eq(lumosListItems.tmdbId, row.tmdbId),
              eq(lumosListItems.origin, row.origin),
              isNull(lumosListItems.removedAt),
            ),
          )
          .get();
        if (active) continue;
        tx.update(lumosListItems)
          .set({ removedAt: null })
          .where(eq(lumosListItems.id, id))
          .run();
        scopes.add(scopeOf(row.ownerId));
      }
      for (const id of effects.verdictsUndone) {
        const row = tx
          .select()
          .from(lumosVerdicts)
          .where(eq(lumosVerdicts.id, id))
          .get();
        if (!row?.undoneAt) continue;
        const active = tx
          .select({ id: lumosVerdicts.id })
          .from(lumosVerdicts)
          .where(
            and(
              this.personIs(lumosVerdicts.personId, row.personId),
              eq(lumosVerdicts.mediaType, row.mediaType),
              eq(lumosVerdicts.tmdbId, row.tmdbId),
              eq(lumosVerdicts.origin, row.origin),
              inArray(lumosVerdicts.kind, [...groupOf(row.kind)]),
              isNull(lumosVerdicts.undoneAt),
            ),
          )
          .get();
        if (active) continue;
        tx.update(lumosVerdicts)
          .set({ undoneAt: null })
          .where(eq(lumosVerdicts.id, id))
          .run();
        scopes.add(scopeOf(row.personId));
      }
      tx.update(lumosChanges)
        .set({ undoneAt: now })
        .where(eq(lumosChanges.id, changeId))
        .run();
    });
    for (const scope of scopes) this.changed(access, scope);
    return { changeId };
  }
}
