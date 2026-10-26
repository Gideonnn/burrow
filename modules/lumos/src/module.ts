import type { SettingDefinition } from '@burrow/contracts';
import { listScope } from '@burrow/contracts';
import { mcpText, type Module, type Platform } from '@burrow/platform';
import { z } from 'zod';
import type { CatalogueProvider, MediaRequester } from './catalogue';
import { Lumos, MODULE } from './lumos';
import { lumosRoutes } from './routes';

const settings: SettingDefinition[] = [
  {
    key: 'lumos.enabled',
    module: MODULE,
    label: 'Lumos (films en series)',
    description:
      'Samen kiezen wat jullie kijken, met lijsten per persoon en samen.',
    type: 'boolean',
    default: true,
    feature: true,
  },
];

export type LumosOptions = {
  // Without one Lumos answers "niet gekoppeld"; lists still work.
  catalogue?: CatalogueProvider;
  // Asks the media server for listed titles; only with the live catalogue.
  requester?: MediaRequester;
};

// Lumos, films and series to watch together: a catalogue from a provider,
// the household's list and each person's own, and "not now" and "seen"
// that can always be undone. The media server stays Seerr, Radarr, Sonarr
// and Jellyfin; a title on a list is requested there, nothing more.
export function lumosModule(platform: Platform, options: LumosOptions = {}) {
  const lumos = new Lumos(platform, options.catalogue, options.requester);

  const module: Module = {
    name: MODULE,
    settings,
    api: lumosRoutes(lumos),
    clients: ['lumos'],
    start: () => lumos.requests?.start(),
    // Read only: requesting media stays with the people.
    mcp: (server, access) => {
      if (!access.rights.has('read')) return;
      server.registerTool(
        'search_titles',
        {
          description:
            'Search films and series in Lumos by title, maker, cast, genre or trait. Says whether the catalogue is test data (dataOrigin).',
          inputSchema: { query: z.string().min(1) },
        },
        async ({ query }) =>
          mcpText(await lumos.search(access, 'shared', query)),
      );
      server.registerTool(
        'list_watchlist',
        {
          description:
            "The household's shared watch list (shared) or the person's own (mine).",
          inputSchema: { scope: listScope.optional() },
        },
        async ({ scope }) =>
          mcpText(await lumos.list(access, scope ?? 'shared')),
      );
    },
  };

  return { module, lumos };
}
