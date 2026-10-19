import { type Db, type PlatformEnv, personByEmail } from '@burrow/platform';
import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { App } from '../app';
import { PUBLIC_PATHS } from '../publicPages';

export type CloudflareAccessOptions = {
  db: Db;
  team: string;
  audience: string;
  keys?: JWTVerifyGetKey;
};

// The app as served to the Cloudflare Tunnel, on its own port. Browser pages
// need an Access login; checking its signed token here as well means a mistake
// in the Access policy does not open them, and only people of the household get
// in. The verified person is passed on, so pages such as the device login know
// who is approving. Access lets /api through so the apps and agents need only
// their key, which every API route requires.
export function behindCloudflareAccess(
  app: App,
  {
    db,
    team,
    audience,
    keys = createRemoteJWKSet(new URL(`https://${team}/cdn-cgi/access/certs`)),
  }: CloudflareAccessOptions,
) {
  const requireLogin = createMiddleware<PlatformEnv>(async (c, next) => {
    if (c.req.path.startsWith('/api/')) return next();
    if ((PUBLIC_PATHS as readonly string[]).includes(c.req.path)) return next();
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
      typeof email === 'string' ? personByEmail(db, email) : undefined;
    if (!person) return c.json({ error: 'not logged in' }, 403);
    c.set('loginPersonId', person.id);
    await next();
  });

  return new Hono<PlatformEnv>().use(requireLogin).route('/', app);
}
