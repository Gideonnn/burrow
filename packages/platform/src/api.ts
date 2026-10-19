import { Hono } from 'hono';
import type { PlatformEnv } from './env';
import { requireKey } from './middleware';
import type { Platform } from './platform';
import { clientRoutes } from './routes/clients';
import { eventRoutes } from './routes/events';
import { fileRoutes } from './routes/files';
import { mcpRoutes } from './routes/mcp';
import { peopleRoutes } from './routes/people';
import { workRoutes } from './routes/work';

export type ApiOptions = {
  version: string;
  // Where signed client builds are published; without it there are no updates.
  clientsDir?: string;
};

// Everything under /api: the platform's own routes and every module's, all
// behind the key check.
export function platformApi(platform: Platform, options: ApiOptions) {
  const api = new Hono<PlatformEnv>()
    .use(requireKey)
    .route('/', peopleRoutes)
    .route('/', workRoutes)
    .route('/', fileRoutes)
    .route('/', eventRoutes)
    .route('/', mcpRoutes(options.version));
  if (options.clientsDir) {
    api.route('/', clientRoutes(options.clientsDir, platform.clients));
  }
  for (const module of platform.modules) {
    if (module.api) api.route('/', module.api);
  }
  return api;
}
