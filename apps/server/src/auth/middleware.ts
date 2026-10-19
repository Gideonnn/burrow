import type { Right } from '@burrow/contracts';
import { createMiddleware } from 'hono/factory';
import { HTTPException } from 'hono/http-exception';
import type { AppEnv } from '../env';
import { resolveAccess } from './access';

export const requireKey = createMiddleware<AppEnv>(async (c, next) => {
  const header = c.req.header('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  const access = token ? resolveAccess(c.var.db, token) : undefined;
  if (!access) {
    throw new HTTPException(401, { message: 'missing or invalid API key' });
  }
  c.set('access', access);
  await next();
});

export const requireRight = (right: Right) =>
  createMiddleware<AppEnv>(async (c, next) => {
    if (!c.var.access.rights.has(right)) {
      throw new HTTPException(403, {
        message: `this key lacks the ${right} right`,
      });
    }
    await next();
  });
