import { eq } from 'drizzle-orm';
import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { App } from '../app';
import type { Db } from '../db/client';
import { people } from '../db/schema';
import type { AppEnv } from '../env';

export type CloudflareAccessOptions = {
  db: Db;
  team: string;
  audience: string;
  keys?: JWTVerifyGetKey;
};

// The app as served to the Cloudflare Tunnel, on its own port. Access already
// asks for a login at Cloudflare; checking its signed token here as well means
// a mistake in the Access policy does not open the server, and only people of
// the household get in. API routes still require a key on top.
export function behindCloudflareAccess(
  app: App,
  {
    db,
    team,
    audience,
    keys = createRemoteJWKSet(new URL(`https://${team}/cdn-cgi/access/certs`)),
  }: CloudflareAccessOptions,
) {
  const requireLogin = createMiddleware<AppEnv>(async (c, next) => {
    const token = c.req.header('cf-access-jwt-assertion');
    const email = token
      ? await jwtVerify(token, keys, {
          issuer: `https://${team}`,
          audience,
          algorithms: ['RS256'],
        }).then(
          ({ payload }) => payload.email,
          () => undefined,
        )
      : undefined;
    const person =
      typeof email === 'string'
        ? db
            .select({ id: people.id })
            .from(people)
            .where(eq(people.email, email.toLowerCase()))
            .get()
        : undefined;
    if (!person) return c.json({ error: 'not logged in' }, 403);
    await next();
  });

  return new Hono<AppEnv>().use(requireLogin).route('/', app);
}
