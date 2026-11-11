import type { Right } from '@burrow/contracts';
import { createMiddleware } from 'hono/factory';
import { HTTPException } from 'hono/http-exception';
import { resolveAccess } from './access';
import type { PlatformEnv } from './env';

export const requireKey = createMiddleware<PlatformEnv>(async (c, next) => {
  const header = c.req.header('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  const access = token
    ? resolveAccess(c.var.db, token, c.var.platform.accessExtenders)
    : undefined;
  if (!access) {
    throw new HTTPException(401, { message: 'missing or invalid API key' });
  }
  c.set('access', access);
  await next();
});

export const requireRight = (right: Right) =>
  createMiddleware<PlatformEnv>(async (c, next) => {
    if (!c.var.access.rights.has(right)) {
      throw new HTTPException(403, {
        message: `this key lacks the ${right} right`,
      });
    }
    await next();
  });

// Outside the key's scope answers 404, not 403, so a key cannot even learn
// that something exists.
export const notFound = () => new HTTPException(404, { message: 'not found' });

// Runs a route's work; errors of these service classes are the caller's
// (404 for "not found", 400 otherwise), anything else stays a 500.
export const httpErrors =
  (...kinds: (abstract new (...args: never[]) => Error)[]) =>
  async <T>(work: () => T | Promise<T>): Promise<T> => {
    try {
      return await work();
    } catch (error) {
      if (!kinds.some((kind) => error instanceof kind)) throw error;
      const { message } = error as Error;
      throw new HTTPException(message === 'not found' ? 404 : 400, {
        message,
      });
    }
  };
