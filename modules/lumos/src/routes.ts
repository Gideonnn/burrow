import {
  createVerdictRequest,
  listScope,
  mediaType,
  playRequest,
  putListItemRequest,
} from '@burrow/contracts';
import { notFound, type PlatformEnv, requireRight } from '@burrow/platform';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { JellyfinError } from './jellyfin';
import { LumosError, type Lumos, NoPlayer, NotConnected } from './lumos';
import { SeerrError } from './seerr';

const scoped = z.object({ scope: listScope.default('shared') });
const ref = z.object({
  mediaType,
  tmdbId: z.coerce.number().int(),
});

const asHttp = (error: unknown): never => {
  if (error instanceof JellyfinError) {
    // A screen without Jellyfin open is the caller's situation, not an outage.
    throw new HTTPException(error.status === 409 ? 409 : 503, {
      message: error.message,
    });
  }
  if (
    error instanceof NotConnected ||
    error instanceof NoPlayer ||
    error instanceof SeerrError
  ) {
    throw new HTTPException(503, { message: error.message });
  }
  if (error instanceof LumosError) {
    if (error.message === 'not found') throw notFound();
    throw new HTTPException(400, { message: error.message });
  }
  throw error;
};

const attempt = async <T>(work: () => T | Promise<T>) => {
  try {
    return await work();
  } catch (error) {
    return asHttp(error);
  }
};

// Catalogue reads need `read`; lists and verdicts `organize`. A personal list
// is always the key's own person's: there is no way to name someone else's.
export function lumosRoutes(lumos: Lumos) {
  const enabled = createMiddleware<PlatformEnv>(async (c, next) => {
    if (
      !c.var.platform.settings.enabled(c.var.access.personId, 'lumos.enabled')
    ) {
      throw new HTTPException(403, { message: 'Lumos staat uit voor jou' });
    }
    await next();
  });

  return (
    new Hono<PlatformEnv>()
      .use('/lumos/*', enabled)
      .get('/lumos/status', requireRight('read'), (c) => c.json(lumos.status()))
      .get(
        '/lumos/rows',
        requireRight('read'),
        zValidator('query', scoped),
        async (c) =>
          c.json(
            await attempt(() =>
              lumos.rows(c.var.access, c.req.valid('query').scope),
            ),
          ),
      )
      .get(
        '/lumos/titles',
        requireRight('read'),
        zValidator(
          'query',
          scoped.extend({
            type: mediaType.optional(),
            available: z.enum(['true', 'false']).optional(),
          }),
        ),
        async (c) => {
          const { scope, type, available } = c.req.valid('query');
          return c.json(
            await attempt(() =>
              lumos.titles(c.var.access, scope, {
                mediaType: type,
                available: available === 'true',
              }),
            ),
          );
        },
      )
      .get(
        '/lumos/search',
        requireRight('read'),
        zValidator(
          'query',
          scoped.extend({ q: z.string().trim().min(1).max(200) }),
        ),
        async (c) => {
          const { scope, q } = c.req.valid('query');
          return c.json(
            await attempt(() => lumos.search(c.var.access, scope, q)),
          );
        },
      )
      .get(
        '/lumos/titles/:mediaType/:tmdbId',
        requireRight('read'),
        zValidator('param', ref),
        zValidator('query', scoped),
        async (c) =>
          c.json(
            await attempt(() =>
              lumos.detail(
                c.var.access,
                c.req.valid('query').scope,
                c.req.valid('param'),
              ),
            ),
          ),
      )
      .get(
        '/lumos/similar/:mediaType/:tmdbId',
        requireRight('read'),
        zValidator('param', ref),
        zValidator('query', scoped),
        async (c) =>
          c.json(
            await attempt(() =>
              lumos.similar(
                c.var.access,
                c.req.valid('query').scope,
                c.req.valid('param'),
              ),
            ),
          ),
      )
      .get(
        '/lumos/credits/:id',
        requireRight('read'),
        zValidator('query', scoped),
        async (c) =>
          c.json(
            await attempt(() =>
              lumos.credit(
                c.var.access,
                c.req.valid('query').scope,
                c.req.param('id'),
              ),
            ),
          ),
      )
      .get(
        '/lumos/lists/:scope',
        requireRight('read'),
        zValidator('param', scoped),
        async (c) =>
          c.json(await lumos.list(c.var.access, c.req.valid('param').scope)),
      )
      .put(
        '/lumos/lists/:scope/items/:mediaType/:tmdbId',
        requireRight('organize'),
        zValidator('param', scoped.extend(ref.shape)),
        zValidator('json', putListItemRequest),
        async (c) => {
          const { scope, ...title } = c.req.valid('param');
          return c.json(
            await attempt(() =>
              lumos.addToList(
                c.var.access,
                scope,
                title,
                c.req.valid('json').seasons,
              ),
            ),
          );
        },
      )
      .delete(
        '/lumos/lists/:scope/items/:mediaType/:tmdbId',
        requireRight('organize'),
        zValidator('param', scoped.extend(ref.shape)),
        (c) => {
          const { scope, ...title } = c.req.valid('param');
          return c.json(lumos.removeFromScope(c.var.access, scope, title));
        },
      )
      .get(
        '/lumos/verdicts',
        requireRight('read'),
        zValidator('query', scoped),
        async (c) =>
          c.json(
            await lumos.verdicts(c.var.access, c.req.valid('query').scope),
          ),
      )
      .post(
        '/lumos/verdicts',
        requireRight('organize'),
        zValidator('json', createVerdictRequest),
        async (c) =>
          c.json(
            await attempt(() =>
              lumos.addVerdict(c.var.access, c.req.valid('json')),
            ),
            201,
          ),
      )
      .delete('/lumos/verdicts/:id', requireRight('organize'), async (c) =>
        c.json(
          await attempt(() =>
            lumos.undoVerdict(c.var.access, c.req.param('id')),
          ),
        ),
      )
      .post(
        '/lumos/requests/:mediaType/:tmdbId/retry',
        requireRight('organize'),
        zValidator('param', ref),
        async (c) =>
          c.json(await attempt(() => lumos.retryRequest(c.req.valid('param')))),
      )
      .post('/lumos/changes/:id/undo', requireRight('organize'), async (c) =>
        c.json(
          await attempt(() => lumos.undo(c.var.access, c.req.param('id'))),
        ),
      )
      .get(
        '/lumos/watch/:mediaType/:tmdbId',
        requireRight('read'),
        zValidator('param', ref),
        async (c) =>
          c.json(await attempt(() => lumos.watch(c.req.valid('param')))),
      )
      // Starting a title on the household's screen is an action on the
      // house, so it takes `organize`, like putting a title on a list.
      .post(
        '/lumos/watch/:mediaType/:tmdbId/screen',
        requireRight('organize'),
        zValidator('param', ref),
        zValidator('json', playRequest),
        async (c) =>
          c.json(
            await attempt(() =>
              lumos.play(c.req.valid('param'), c.req.valid('json').deviceId),
            ),
          ),
      )
  );
}
