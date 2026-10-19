import type { HealthResponse } from '@burrow/contracts';
import { Hono } from 'hono';

export type AppOptions = {
  version: string;
};

export function createApp({ version }: AppOptions) {
  const app = new Hono();

  app.get('/health', (c) =>
    c.json<HealthResponse>({ status: 'ok', service: 'burrow-server', version }),
  );

  return app;
}
