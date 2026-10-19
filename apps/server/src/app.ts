import type { HealthResponse } from '@burrow/contracts';
import { type Platform, type PlatformEnv, platformApi } from '@burrow/platform';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { deviceLogin } from './auth/deviceLogin';

export type AppOptions = {
  version: string;
  platform: Platform;
  // Where signed client builds are published; without it there are no updates.
  clientsDir?: string;
  // Development only: who the device login assumes without Cloudflare Access.
  devLoginAs?: string;
};

// The whole HTTP surface: health, the device login, every module's browser
// pages, and the API under /api.
export function createApp({
  version,
  platform,
  clientsDir,
  devLoginAs,
}: AppOptions) {
  const app = new Hono<PlatformEnv>();

  app.use(async (c, next) => {
    c.set('db', platform.db);
    c.set('events', platform.events);
    c.set('platform', platform);
    await next();
  });

  app.get('/health', (c) =>
    c.json<HealthResponse>({ status: 'ok', service: 'burrow-server', version }),
  );

  app.route(
    '/',
    deviceLogin({ publicUrl: platform.publicUrl, devPersonName: devLoginAs }),
  );
  for (const module of platform.modules) {
    if (module.browser) app.route('/', module.browser);
  }
  app.route('/api', platformApi(platform, { version, clientsDir }));

  app.onError((error, c) => {
    if (error instanceof HTTPException) {
      return c.json({ error: error.message }, error.status);
    }
    console.error(error);
    return c.json({ error: 'internal error' }, 500);
  });

  return app;
}

export type App = ReturnType<typeof createApp>;
