import type {
  Disk,
  Episode,
  MediaFacts,
  OnServer,
  PlayResponse,
  PlayState,
  ResumePoint,
  Screen,
} from '@burrow/contracts';
import { refKey, type CatalogueTitle, type TitleRef } from './catalogue';

// Watching: the household's Jellyfin. It answers which screens have its app
// open (the TV), starts a title on one through the sessions API, and gives
// the title's page for a browser on this machine. One service key, like
// Seerr's; it never leaves this file. It also reads, never writes, what the
// household's one account has played and where it stopped, the files'
// sizes and facts, and the disks. Nothing is ever marked or deleted here.

export type JellyfinOptions = {
  url: string;
  apiKey: string;
  // The address browsers in the house reach, when it is not `url`.
  webUrl?: string;
  // The household's shared account, by name or id. Without it nothing
  // per user is read; another account is never guessed.
  user?: string;
  fetch?: typeof fetch;
  // Between the checks whether the screen really plays; tests skip it.
  sleep?: (ms: number) => Promise<void>;
};

// Lumos's own device id, so its calls never count as a screen.
const DEVICE_ID = 'burrow-lumos';
const CONFIRM_ATTEMPTS = 6;
const CONFIRM_WAIT_MS = 1_000;
// The library and the disks are read at most this often.
const LIBRARY_TTL = 60_000;
const TICKS_PER_SECOND = 10_000_000;
const languageNames = new Intl.DisplayNames(['nl'], { type: 'language' });

export class JellyfinError extends Error {
  constructor(
    message: string,
    readonly status: number | null = null,
  ) {
    super(message);
  }
}

type UserData = {
  Played?: boolean;
  PlayCount?: number;
  LastPlayedDate?: string;
  PlaybackPositionTicks?: number;
  UnplayedItemCount?: number;
};

type Stream = {
  Type?: string;
  Language?: string;
  Width?: number;
  Height?: number;
  VideoRangeType?: string;
  VideoRange?: string;
};

type Item = {
  Id: string;
  Name?: string;
  Type?: string;
  IndexNumber?: number;
  ParentIndexNumber?: number;
  ProviderIds?: Record<string, string>;
  SeriesId?: string;
  RunTimeTicks?: number;
  RecursiveItemCount?: number;
  MediaSources?: { Size?: number; MediaStreams?: Stream[] }[];
  UserData?: UserData;
};

type Folder = {
  Path?: string;
  FreeSpace?: number;
  UsedSpace?: number;
  DeviceId?: string;
};

export type TitleFacts = OnServer & { itemId: string; key: string | null };

// A title as the catalogue knows it: Seerr passes on Jellyfin's own id.
type Findable = TitleRef & { mediaServerId?: string | null };

const plainId = (id: string) => id.replaceAll('-', '').toLowerCase();

// What Jellyfin holds, found by the item id Seerr knows, else by the TMDB
// id. Many files carry no TMDB id, so the first is the one that counts.
export class LibraryFacts {
  private readonly byId = new Map<string, TitleFacts>();
  private readonly byKey = new Map<string, TitleFacts>();

  add(facts: TitleFacts) {
    this.byId.set(plainId(facts.itemId), facts);
    if (facts.key) this.byKey.set(facts.key, facts);
  }

  get(t: Findable): TitleFacts | null {
    const known = t.mediaServerId
      ? this.byId.get(plainId(t.mediaServerId))
      : undefined;
    return known ?? this.byKey.get(refKey(t)) ?? null;
  }

  byItem(itemId: string) {
    return this.byId.get(plainId(itemId)) ?? null;
  }

  all() {
    return [...this.byId.values()];
  }
}

// Something the household account is in the middle of.
export type Going = {
  // The film's or the series' item.
  itemId: string;
  key: string | null;
  resume: ResumePoint;
};

const tmdbOf = (i: Item) =>
  Object.entries(i.ProviderIds ?? {}).find(
    ([key]) => key.toLowerCase() === 'tmdb',
  )?.[1];

const seconds = (ticks: number | undefined) =>
  ticks ? Math.round(ticks / TICKS_PER_SECOND) : null;

const resolution = (v: Stream | undefined) => {
  if (!v?.Width && !v?.Height) return null;
  const w = v.Width ?? 0;
  const h = v.Height ?? 0;
  if (w >= 3200 || h >= 2000) return '4K';
  if (w >= 1800 || h >= 1000) return '1080p';
  if (w >= 1200 || h >= 700) return '720p';
  return 'SD';
};

const HDR: Record<string, string> = {
  HDR10: 'HDR10',
  HDR10Plus: 'HDR10+',
  HLG: 'HLG',
};
const hdr = (v: Stream | undefined) => {
  const type = v?.VideoRangeType ?? '';
  if (type.startsWith('DOVI')) return 'Dolby Vision';
  if (HDR[type]) return HDR[type];
  return v?.VideoRange === 'HDR' ? 'HDR' : null;
};

const languages = (streams: Stream[], type: string) => {
  const names: string[] = [];
  for (const s of streams) {
    const code = s.Type === type ? s.Language?.trim().toLowerCase() : undefined;
    if (!code || ['und', 'zxx', 'mis', 'mul'].includes(code)) continue;
    let name = code;
    try {
      name = languageNames.of(code) ?? code;
    } catch {}
    if (!names.includes(name)) names.push(name);
  }
  return names;
};

function mediaFactsOf(item: Item | undefined): MediaFacts | null {
  const streams = item?.MediaSources?.[0]?.MediaStreams ?? [];
  if (!streams.length) return null;
  const video = streams.find((s) => s.Type === 'Video');
  return {
    resolution: resolution(video),
    hdr: hdr(video),
    audio: languages(streams, 'Audio'),
    subtitles: languages(streams, 'Subtitle'),
  };
}

const sizeOf = (items: Item[]) => {
  let total = 0;
  let known = false;
  for (const i of items) {
    for (const source of i.MediaSources ?? []) {
      if (source.Size) {
        total += source.Size;
        known = true;
      }
    }
  }
  return known ? total : null;
};

const episodeOf = (i: Item): Episode => ({
  season: i.ParentIndexNumber ?? 1,
  number: i.IndexNumber ?? 1,
  title: i.Name ?? null,
});

const resumeOf = (i: Item, episode: boolean): ResumePoint | null => {
  const position = seconds(i.UserData?.PlaybackPositionTicks);
  if (!episode && (!position || i.UserData?.Played)) return null;
  return {
    positionSeconds: position ?? 0,
    runtimeSeconds: seconds(i.RunTimeTicks),
    episode: episode ? episodeOf(i) : null,
  };
};

type Session = {
  Id: string;
  UserId?: string;
  Client?: string;
  DeviceName?: string;
  DeviceId?: string;
  SupportsRemoteControl?: boolean;
  NowPlayingItem?: Item;
};

export type LibraryItem = { id: string; name: string; type: 'movie' | 'tv' };
export type ScreenSession = Screen & { userId: string | null };

const toScreen = (s: Session): ScreenSession => ({
  deviceId: s.DeviceId ?? '',
  name: s.DeviceName || s.Client || 'Scherm',
  client: s.Client ?? '',
  playing: s.NowPlayingItem?.Name ?? null,
  userId: s.UserId ?? null,
});

export class JellyfinPlayer {
  readonly name = 'Jellyfin';
  private readonly base: string;
  private readonly web: string;
  private readonly fetcher: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;
  private serverId?: Promise<string | null>;
  private userId?: Promise<string | null>;
  private libraryCache?: { at: number; value: Promise<LibraryFacts> };
  private diskCache?: { at: number; value: Promise<Disk | null> };

  constructor(private readonly options: JellyfinOptions) {
    this.base = options.url.replace(/\/+$/, '');
    this.web = (options.webUrl ?? options.url).replace(/\/+$/, '');
    this.fetcher = options.fetch ?? fetch;
    this.sleep =
      options.sleep ??
      ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  private async call<T>(
    path: string,
    query: Record<string, string> = {},
    init: RequestInit = {},
  ): Promise<T> {
    const url = new URL(`${this.base}${path}`);
    for (const [key, value] of Object.entries(query)) {
      url.searchParams.set(key, value);
    }
    let response: Response;
    try {
      response = await this.fetcher(url, {
        ...init,
        headers: {
          Authorization: `MediaBrowser Token="${this.options.apiKey}", Client="Burrow", Device="Lumos", DeviceId="${DEVICE_ID}", Version="1"`,
          Accept: 'application/json',
          ...init.headers,
        },
      });
    } catch {
      throw new JellyfinError('Jellyfin is niet bereikbaar');
    }
    if (!response.ok) {
      throw new JellyfinError(
        `Jellyfin antwoordde ${response.status}`,
        response.status,
      );
    }
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  // The library's item for a title: by the id the catalogue already knows,
  // else the item with that name whose TMDB id matches. Null when the
  // library does not have it, whatever the catalogue claims.
  async item(title: CatalogueTitle): Promise<LibraryItem | null> {
    const found = (i: Item): LibraryItem => ({
      id: i.Id,
      name: i.Name ?? title.title,
      type: title.mediaType,
    });
    if (title.mediaServerId) {
      // Not /Items/{id}: since Jellyfin 12 that answers 400 without a userId.
      const known = await this.call<{ Items?: Item[] }>('/Items', {
        ids: title.mediaServerId,
        fields: 'ProviderIds',
      });
      const item = known.Items?.find((i) => i.Id === title.mediaServerId);
      if (item) return found(item);
    }
    const page = await this.call<{ Items?: Item[] }>('/Items', {
      recursive: 'true',
      includeItemTypes: title.mediaType === 'movie' ? 'Movie' : 'Series',
      searchTerm: title.title,
      fields: 'ProviderIds',
      limit: '20',
    });
    const match = (page.Items ?? []).find(
      (i) => tmdbOf(i) === String(title.tmdbId),
    );
    return match ? found(match) : null;
  }

  // The household account's id: the configured name or id, matched
  // exactly. Null when none is configured or none matches.
  private user(): Promise<string | null> {
    const wanted = this.options.user?.trim();
    if (!wanted) return Promise.resolve(null);
    this.userId ??= this.call<{ Id: string; Name?: string }[]>('/Users')
      .then(
        (users) =>
          users.find(
            (u) =>
              plainId(u.Id) === plainId(wanted) ||
              u.Name?.toLowerCase() === wanted.toLowerCase(),
          )?.Id ?? null,
      )
      .catch(() => {
        this.userId = undefined;
        return null;
      });
    return this.userId;
  }

  // Whether a household account is configured at all.
  get readsUser() {
    return Boolean(this.options.user?.trim());
  }

  // Every film and series in the library with its size, its media facts
  // and, for the household account, what was played and where it stopped.
  // A handful of calls for the whole library, cached for a minute.
  library(): Promise<LibraryFacts> {
    const now = Date.now();
    if (this.libraryCache && now - this.libraryCache.at < LIBRARY_TTL) {
      return this.libraryCache.value;
    }
    const value = this.loadLibrary();
    this.libraryCache = { at: now, value };
    value.catch(() => {
      if (this.libraryCache?.value === value) this.libraryCache = undefined;
    });
    return value;
  }

  private async loadLibrary(): Promise<LibraryFacts> {
    const userId = await this.user();
    const user: Record<string, string> = userId ? { userId } : {};
    const common = { recursive: 'true', enableImages: 'false', ...user };
    const [titles, episodes, next] = await Promise.all([
      this.call<{ Items?: Item[] }>('/Items', {
        ...common,
        includeItemTypes: 'Movie,Series',
        fields: 'ProviderIds,MediaSources,RecursiveItemCount',
      }),
      this.call<{ Items?: Item[] }>('/Items', {
        ...common,
        includeItemTypes: 'Episode',
        fields: 'MediaSources',
      }),
      userId
        ? this.call<{ Items?: Item[] }>('/Shows/NextUp', {
            userId,
            limit: '100',
            enableImages: 'false',
          })
        : Promise.resolve({ Items: [] as Item[] }),
    ]);
    const bySeries = new Map<string, Item[]>();
    for (const e of episodes.Items ?? []) {
      if (!e.SeriesId) continue;
      bySeries.set(e.SeriesId, [...(bySeries.get(e.SeriesId) ?? []), e]);
    }
    const nextUp = new Map(
      (next.Items ?? []).flatMap((e) => (e.SeriesId ? [[e.SeriesId, e]] : [])),
    );
    const facts = new LibraryFacts();
    for (const i of titles.Items ?? []) {
      const tmdb = tmdbOf(i);
      if (i.Type === 'Movie') {
        facts.add({
          itemId: i.Id,
          key: tmdb ? `movie:${tmdb}` : null,
          sizeBytes: sizeOf([i]),
          media: mediaFactsOf(i),
          watched: userId
            ? {
                played: Boolean(i.UserData?.Played),
                playCount: i.UserData?.PlayCount ?? 0,
                lastPlayed: i.UserData?.LastPlayedDate ?? null,
                episodesPlayed: null,
                episodes: null,
                resume: resumeOf(i, false),
              }
            : null,
        });
      } else if (i.Type === 'Series') {
        const eps = bySeries.get(i.Id) ?? [];
        const total = i.RecursiveItemCount ?? eps.length;
        const played = eps.filter((e) => e.UserData?.Played).length;
        const unplayed = i.UserData?.UnplayedItemCount;
        const last = eps
          .map((e) => e.UserData?.LastPlayedDate)
          .filter((d): d is string => Boolean(d))
          .sort()
          .at(-1);
        const upNext = nextUp.get(i.Id);
        const watched: PlayState | null = userId
          ? {
              played: Boolean(i.UserData?.Played),
              playCount: i.UserData?.PlayCount ?? 0,
              lastPlayed: last ?? i.UserData?.LastPlayedDate ?? null,
              episodesPlayed:
                eps.length || unplayed === undefined
                  ? played
                  : Math.max(0, total - unplayed),
              episodes: total,
              resume: upNext ? resumeOf(upNext, true) : null,
            }
          : null;
        facts.add({
          itemId: i.Id,
          key: tmdb ? `tv:${tmdb}` : null,
          sizeBytes: sizeOf(eps),
          media: mediaFactsOf(eps.find((e) => mediaFactsOf(e))),
          watched,
        });
      }
    }
    return facts;
  }

  // What the household account is in the middle of, most recent first:
  // a film or episode it stopped in, then the next episode of a series.
  async continueWatching(): Promise<Going[]> {
    const userId = await this.user();
    if (!userId) return [];
    const [facts, resumable] = await Promise.all([
      this.library(),
      this.call<{ Items?: Item[] }>('/UserItems/Resume', {
        userId,
        includeItemTypes: 'Movie,Episode',
        fields: 'ProviderIds',
        enableImages: 'false',
        limit: '20',
      }),
    ]);
    const found: Going[] = [];
    const seen = new Set<string>();
    const add = (itemId: string, resume: ResumePoint | null) => {
      const known = facts.byItem(itemId);
      if (!resume || seen.has(plainId(itemId))) return;
      seen.add(plainId(itemId));
      found.push({ itemId, key: known?.key ?? null, resume });
    };
    for (const i of resumable.Items ?? []) {
      if (i.Type === 'Movie') add(i.Id, resumeOf(i, false));
      else if (i.Type === 'Episode' && i.SeriesId) {
        add(i.SeriesId, resumeOf(i, true));
      }
    }
    for (const f of facts.all()) {
      if (f.watched?.resume?.episode) add(f.itemId, f.watched.resume);
    }
    return found;
  }

  // The disks under the media libraries, each device once. Null when
  // Jellyfin does not say.
  disk(): Promise<Disk | null> {
    const now = Date.now();
    if (this.diskCache && now - this.diskCache.at < LIBRARY_TTL) {
      return this.diskCache.value;
    }
    const value = this.call<{ Libraries?: { Folders?: Folder[] }[] }>(
      '/System/Info/Storage',
    )
      .then((storage) => {
        const devices = new Map<string, Folder>();
        for (const library of storage.Libraries ?? []) {
          for (const f of library.Folders ?? []) {
            if (f.FreeSpace == null || f.UsedSpace == null) continue;
            devices.set(f.DeviceId || f.Path || String(devices.size), f);
          }
        }
        if (!devices.size) return null;
        let free = 0;
        let used = 0;
        for (const f of devices.values()) {
          free += f.FreeSpace ?? 0;
          used += f.UsedSpace ?? 0;
        }
        return { totalBytes: free + used, freeBytes: free };
      })
      .catch(() => null);
    this.diskCache = { at: now, value };
    return value;
  }

  // What Jellyfin knows of one title, from the library read above.
  async facts(t: Findable) {
    return (await this.library()).get(t);
  }

  async webUrl(item: LibraryItem): Promise<string> {
    const serverId = await this.server();
    const server = serverId ? `&serverId=${serverId}` : '';
    return `${this.web}/web/index.html#!/details?id=${item.id}${server}`;
  }

  private server(): Promise<string | null> {
    this.serverId ??= this.call<{ Id?: string }>('/System/Info/Public')
      .then((info) => info.Id ?? null)
      .catch(() => {
        this.serverId = undefined;
        return null;
      });
    return this.serverId;
  }

  private async sessions(): Promise<Session[]> {
    const all = await this.call<Session[]>('/Sessions');
    return all.filter(
      (s) => s.SupportsRemoteControl && s.DeviceId && s.DeviceId !== DEVICE_ID,
    );
  }

  async screens(): Promise<ScreenSession[]> {
    return (await this.sessions()).map(toScreen);
  }

  // The episode a screen would start: the next unwatched one for that
  // screen's user, else the first one the library has.
  async episode(
    item: LibraryItem,
    userId?: string | null,
  ): Promise<{
    id: string;
    episode: Episode;
    positionSeconds: number | null;
  } | null> {
    if (item.type !== 'tv') return null;
    const user: Record<string, string> = userId ? { userId } : {};
    let found: Item | undefined;
    if (userId) {
      const next = await this.call<{ Items?: Item[] }>('/Shows/NextUp', {
        ...user,
        seriesId: item.id,
        limit: '1',
      });
      found = next.Items?.[0];
    }
    if (!found) {
      const first = await this.call<{ Items?: Item[] }>(
        `/Shows/${encodeURIComponent(item.id)}/Episodes`,
        { ...user, limit: '1', isMissing: 'false' },
      );
      found = first.Items?.[0];
    }
    return found
      ? {
          id: found.Id,
          episode: episodeOf(found),
          positionSeconds: userId
            ? seconds(found.UserData?.PlaybackPositionTicks)
            : null,
        }
      : null;
  }

  // Where a user stopped in a film; null when it was seen to the end.
  private async position(itemId: string, userId: string | null) {
    if (!userId) return null;
    const found = await this.call<{ Items?: Item[] }>('/Items', {
      ids: itemId,
      userId,
      enableImages: 'false',
    });
    const item = found.Items?.find((i) => i.Id === itemId);
    return item && !item.UserData?.Played
      ? seconds(item.UserData?.PlaybackPositionTicks)
      : null;
  }

  // Starts the title on the screen with that device id, then asks the
  // screen whether it plays. `confirmed` is the screen's own word.
  async play(deviceId: string, item: LibraryItem): Promise<PlayResponse> {
    const session = (await this.sessions()).find(
      (s) => s.DeviceId === deviceId,
    );
    if (!session) {
      throw new JellyfinError('Op dat scherm is Jellyfin niet open', 409);
    }
    // The TV's own account decides where it stopped; else the household's.
    const userId = session.UserId ?? (await this.user());
    const next = await this.episode(item, userId);
    if (item.type === 'tv' && !next) {
      throw new JellyfinError(
        'Jellyfin heeft nog geen aflevering van deze serie',
        409,
      );
    }
    const itemId = next?.id ?? item.id;
    const start = next
      ? next.positionSeconds
      : await this.position(item.id, userId);
    const command: Record<string, string> = {
      playCommand: 'PlayNow',
      itemIds: itemId,
    };
    if (start) {
      command.startPositionTicks = String(start * TICKS_PER_SECOND);
    }
    await this.call(
      `/Sessions/${encodeURIComponent(session.Id)}/Playing`,
      command,
      { method: 'POST' },
    );
    let latest = session;
    let confirmed = false;
    for (let i = 0; i < CONFIRM_ATTEMPTS && !confirmed; i++) {
      await this.sleep(CONFIRM_WAIT_MS);
      const now = (await this.sessions()).find((s) => s.Id === session.Id);
      if (now) latest = now;
      confirmed = now?.NowPlayingItem?.Id === itemId;
    }
    const { userId: _user, ...screen } = toScreen(latest);
    return {
      screen,
      episode: next?.episode ?? null,
      confirmed,
      ...(start ? { startSeconds: start } : {}),
    };
  }
}
