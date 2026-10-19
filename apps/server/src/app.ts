import type { HealthResponse } from '@burrow/contracts';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { requireKey } from './auth/middleware';
import type { Db } from './db/client';
import type { AppEnv } from './env';
import type { EventBus } from './events';
import type { MailService } from './mail/service';
import { accessRoutes } from './routes/access';
import { mailRoutes } from './routes/mail';

export type AppOptions = {
  version: string;
  db: Db;
  mail: MailService;
  events: EventBus;
  onArrived?: (messageIds: string[]) => void;
};

export function createApp({
  version,
  db,
  mail,
  events,
  onArrived = () => {},
}: AppOptions) {
  const app = new Hono<AppEnv>();

  app.use(async (c, next) => {
    c.set('db', db);
    c.set('mail', mail);
    c.set('events', events);
    c.set('onArrived', onArrived);
    await next();
  });

  app.get('/health', (c) =>
    c.json<HealthResponse>({ status: 'ok', service: 'burrow-server', version }),
  );

  const api = new Hono<AppEnv>()
    .use(requireKey)
    .route('/', accessRoutes)
    .route('/', mailRoutes);
  app.route('/api', api);

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
