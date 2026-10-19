import type { HealthResponse } from '@burrow/contracts';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { requireKey } from './auth/middleware';
import type { Catalog } from './catalog/loadCatalog';
import type { Db } from './db/client';
import type { AppEnv } from './env';
import type { EventBus } from './events';
import type { Accounts } from './mail/accounts';
import type { MailService } from './mail/service';
import { accessRoutes } from './routes/access';
import { catalogRoutes } from './routes/catalog';
import { connectRoutes } from './routes/connect';
import { draftRoutes } from './routes/drafts';
import { mailRoutes } from './routes/mail';
import { mcpRoutes } from './routes/mcp';
import { triageRoutes } from './routes/triage';
import type { TriageService } from './triage/service';

export type AppOptions = {
  version: string;
  db: Db;
  mail: MailService;
  events: EventBus;
  onArrived?: (messageIds: string[]) => void;
  // Without accounts the server cannot connect new OAuth mailboxes.
  accounts?: Accounts;
  triage?: TriageService;
  catalog?: Catalog;
};

export function createApp({
  version,
  db,
  mail,
  events,
  onArrived = () => {},
  accounts,
  triage,
  catalog,
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
    .route('/', mailRoutes)
    .route('/', draftRoutes)
    .route('/', mcpRoutes(version));
  if (triage) api.route('/', triageRoutes(triage));
  if (catalog) api.route('/', catalogRoutes(catalog));
  if (accounts) {
    const connect = connectRoutes(accounts);
    api.route('/', connect.api);
    app.route('/', connect.browser);
  }
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
