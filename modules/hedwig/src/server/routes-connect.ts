import { randomBytes } from 'node:crypto';
import { person, type PlatformEnv, requireRight } from '@burrow/platform';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { html } from 'hono/html';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { authorizationUrl, pkce } from '../oauth';
import type { Accounts, OAuthMailProvider } from './accounts';
import type { MailService } from './mail-service';

type Pending = {
  personId: string;
  provider: OAuthMailProvider;
  verifier: string;
  expiresAt: number;
};

const TTL_MS = 10 * 60_000;

const fastmailRequest = z.object({
  personId: z.string(),
  token: z.string().trim().min(10),
});

const connectRequest = z.object({
  personId: z.string(),
  provider: z.enum(['gmail', 'microsoft']),
});

// Connecting an OAuth account in three steps:
// 1. an admin client asks for a one-time link (POST /api/admin/accounts/connect);
// 2. the browser opens it (GET /oauth/start/:handle) and is sent to the
//    provider, so the person logs in on the provider's own page;
// 3. the provider redirects back (GET /oauth/callback) and the server stores
//    the mailbox. The password never reaches Burrow, and the one-time handle
//    means the browser needs no API key.
// An admin may connect a mailbox for the other person: that person logs in at
// the provider themselves, and the mailbox is theirs, so the admin still
// cannot read it.
export function connectRoutes(
  accounts: Accounts,
  mail: MailService,
  onArrived: (messageIds: string[]) => void,
) {
  const pending = new Map<string, Pending>();
  const take = (handle: string | undefined) => {
    for (const [h, p] of pending)
      if (p.expiresAt < Date.now()) pending.delete(h);
    const entry = handle ? pending.get(handle) : undefined;
    if (handle) pending.delete(handle);
    return entry;
  };

  const api = new Hono<PlatformEnv>()
    .post(
      '/admin/accounts/connect',
      requireRight('admin'),
      zValidator('json', connectRequest),
      (c) => {
        const { personId, provider } = c.req.valid('json');
        if (!accounts.isConfigured(provider)) {
          throw new HTTPException(400, {
            message: `${provider} is not configured on this server`,
          });
        }
        if (!person(c.var.db, personId))
          throw new HTTPException(400, { message: 'unknown person' });
        const handle = randomBytes(24).toString('base64url');
        pending.set(handle, {
          personId,
          provider,
          verifier: '',
          expiresAt: Date.now() + TTL_MS,
        });
        return c.json({
          url: `${accounts.publicUrl}/oauth/start/${handle}`,
        });
      },
    )
    // Fastmail only allows OAuth for registered partner apps, so a person
    // pastes an API token instead; the server checks it before storing.
    .post(
      '/admin/accounts/fastmail',
      requireRight('admin'),
      zValidator('json', fastmailRequest),
      async (c) => {
        const { personId, token } = c.req.valid('json');
        if (!person(c.var.db, personId))
          throw new HTTPException(400, { message: 'unknown person' });
        const credentials = { kind: 'token' as const, token };
        let address: string;
        try {
          address = await accounts.probe('fastmail', credentials).address();
        } catch (error) {
          throw new HTTPException(400, {
            message: `Fastmail did not accept the token: ${(error as Error).message}`,
          });
        }
        const mailbox = accounts.upsertMailbox({
          ownerId: personId,
          provider: 'fastmail',
          address,
          credentials,
        });
        void mail
          .sync(mailbox.id)
          .then(onArrived)
          .catch((error: Error) =>
            console.error(`first sync of ${address} failed: ${error.message}`),
          );
        return c.json({ id: mailbox.id, address }, 201);
      },
    );

  const browser = new Hono<PlatformEnv>()
    .get('/oauth/start/:handle', (c) => {
      const handle = c.req.param('handle');
      const entry = pending.get(handle);
      if (!entry || entry.expiresAt < Date.now()) {
        return c.html(
          page('Deze link is verlopen', 'Vraag in Hedwig een nieuwe aan.'),
          410,
        );
      }
      const { verifier, challenge } = pkce();
      entry.verifier = verifier;
      return c.redirect(
        authorizationUrl(
          accounts.oauthProvider(entry.provider),
          accounts.oauthClient(entry.provider),
          handle,
          challenge,
        ),
      );
    })
    .get('/oauth/callback', async (c) => {
      const entry = take(c.req.query('state'));
      if (!entry || !entry.verifier) {
        return c.html(
          page('Deze link is verlopen', 'Vraag in Hedwig een nieuwe aan.'),
          410,
        );
      }
      const code = c.req.query('code');
      if (!code) {
        return c.html(
          page('Niet gekoppeld', 'Het inloggen is afgebroken.'),
          400,
        );
      }
      const credentials = await accounts.exchange(
        entry.provider,
        code,
        entry.verifier,
      );
      const address = await accounts
        .probe(entry.provider, credentials)
        .address();
      const mailbox = accounts.upsertMailbox({
        ownerId: entry.personId,
        provider: entry.provider,
        address,
        credentials,
      });
      void mail
        .sync(mailbox.id)
        .then(onArrived)
        .catch((error: Error) =>
          console.error(`first sync of ${address} failed: ${error.message}`),
        );
      return c.html(
        page(`${address} is gekoppeld`, 'Je kunt dit venster sluiten.'),
      );
    });

  return { api, browser };
}

const page = (title: string, text: string) =>
  html`<!doctype html>
    <html lang="nl">
      <meta charset="utf-8" />
      <title>${title}</title>
      <body
        style="font-family: -apple-system, sans-serif; margin: 15vh auto; max-width: 28rem; text-align: center"
      >
        <h1 style="font-size: 1.4rem">${title}</h1>
        <p style="color: #666">${text}</p>
      </body>
    </html>`;
