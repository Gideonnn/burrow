import type { Episode, PlayResponse, Screen } from '@burrow/contracts';
import type { CatalogueTitle } from './catalogue';

// Watching: the household's Jellyfin. It answers which screens have its app
// open (the TV), starts a title on one through the sessions API, and gives
// the title's page for a browser on this machine. One service key, like
// Seerr's; it never leaves this file. The library is never changed from
// here: no deletes, no marks, no user data.

export type JellyfinOptions = {
  url: string;
  apiKey: string;
  // The address browsers in the house reach, when it is not `url`.
  webUrl?: string;
  fetch?: typeof fetch;
  // Between the checks whether the screen really plays; tests skip it.
  sleep?: (ms: number) => Promise<void>;
};

// Lumos's own device id, so its calls never count as a screen.
const DEVICE_ID = 'burrow-lumos';
const CONFIRM_ATTEMPTS = 6;
const CONFIRM_WAIT_MS = 1_000;

export class JellyfinError extends Error {
  constructor(
    message: string,
    readonly status: number | null = null,
  ) {
    super(message);
  }
}

type Item = {
  Id: string;
  Name?: string;
  Type?: string;
  IndexNumber?: number;
  ParentIndexNumber?: number;
  ProviderIds?: Record<string, string>;
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
    const wanted = String(title.tmdbId);
    const match = (page.Items ?? []).find((i) =>
      Object.entries(i.ProviderIds ?? {}).some(
        ([key, value]) => key.toLowerCase() === 'tmdb' && value === wanted,
      ),
    );
    return match ? found(match) : null;
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
  ): Promise<(Episode & { id: string }) | null> {
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
          season: found.ParentIndexNumber ?? 1,
          number: found.IndexNumber ?? 1,
          title: found.Name ?? null,
        }
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
    const episode = await this.episode(item, session.UserId);
    if (item.type === 'tv' && !episode) {
      throw new JellyfinError(
        'Jellyfin heeft nog geen aflevering van deze serie',
        409,
      );
    }
    const itemId = episode?.id ?? item.id;
    await this.call(
      `/Sessions/${encodeURIComponent(session.Id)}/Playing`,
      { playCommand: 'PlayNow', itemIds: itemId },
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
      episode: episode
        ? {
            season: episode.season,
            number: episode.number,
            title: episode.title,
          }
        : null,
      confirmed,
    };
  }
}
