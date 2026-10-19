import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import {
  type LoginTokenResponse,
  loginTokenRequest,
  type Right,
} from '@burrow/contracts';
import {
  createKey,
  person,
  personByName,
  type PlatformEnv,
} from '@burrow/platform';
import { zValidator } from '@hono/zod-validator';
import type { Context } from 'hono';
import { Hono } from 'hono';
import { html } from 'hono/html';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';

// Logging in on a new Mac, RFC 8252 style:
// 1. the app opens /login/device in the browser with a PKCE challenge and a
//    loopback address it listens on;
// 2. on the tunnel that page is behind Cloudflare Access, so the server knows
//    who is in front of it; the person presses "Toestaan";
// 3. the browser is sent to the loopback address with a one-time code;
// 4. the app trades code and verifier for a device key (POST /api/login/token).
// Only loopback addresses are accepted, so a link someone else made can only
// ever deliver a code to the Mac of the person who clicks it, and without the
// verifier that app never had, a stolen code is worthless.

const CODE_TTL_MS = 2 * 60_000;
const REQUEST_TTL_MS = 10 * 60_000;
const MAX_PENDING = 50;

const loginQuery = z.object({
  app: z.string().regex(/^[a-z][a-z0-9-]{1,30}$/),
  device: z
    .string()
    .trim()
    .min(1)
    .max(60)
    .regex(/^[\p{L}\p{N} '’._()-]+$/u),
  challenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  state: z.string().regex(/^[A-Za-z0-9_-]{16,128}$/),
  redirect: z.string().refine(isLoopback, 'only a loopback address'),
});

type Pending = z.infer<typeof loginQuery> & {
  personId: string;
  expiresAt: number;
  code?: string;
};

export type DeviceLoginOptions = {
  publicUrl: string;
  // Without Cloudflare Access (development), this person is assumed for
  // requests from this machine itself.
  devPersonName?: string;
};

export function deviceLogin({ publicUrl, devPersonName }: DeviceLoginOptions) {
  const pending = new Map<string, Pending>();
  const sweep = () => {
    for (const [id, p] of pending)
      if (p.expiresAt < Date.now()) pending.delete(id);
  };

  const who = (c: Context<PlatformEnv>) => {
    if (c.var.loginPersonId) return c.var.loginPersonId;
    if (!devPersonName) return undefined;
    const host = (c.req.header('host') ?? '').replace(/:\d+$/, '');
    if (host !== '127.0.0.1' && host !== 'localhost') return undefined;
    return personByName(c.var.db, devPersonName)?.id;
  };

  return new Hono<PlatformEnv>()
    .get('/login/device', zValidator('query', loginQuery), (c) => {
      const personId = who(c);
      if (!personId) {
        return c.html(
          page('Inloggen kan alleen via het huisadres', [
            html`<p>
              Open deze pagina via ${publicUrl}, zodat je huishouden je herkent.
            </p>`,
          ]),
          403,
        );
      }
      sweep();
      if (pending.size >= MAX_PENDING) {
        return c.html(
          page('Te veel aanvragen', [html`<p>Probeer het zo opnieuw.</p>`]),
          429,
        );
      }
      const request = c.req.valid('query');
      const id = randomBytes(24).toString('base64url');
      pending.set(id, {
        ...request,
        personId,
        expiresAt: Date.now() + REQUEST_TTL_MS,
      });
      const name = person(c.var.db, personId)!.name;
      const app = title(request.app);
      return c.html(
        page(`${app} op ${request.device} wil inloggen als ${name}`, [
          html`<p>
              Druk alleen op Toestaan als je dit zelf net op die Mac hebt
              gevraagd. ${app} krijgt dan een eigen sleutel, die je later onder
              Instellingen › Huishouden weer kunt intrekken.
            </p>
            <form method="post" action="/login/device/approve">
              <input type="hidden" name="request" value="${id}" />
              <button name="answer" value="deny" class="secondary">
                Weigeren
              </button>
              <button name="answer" value="allow">Toestaan</button>
            </form>`,
        ]),
      );
    })
    .post('/login/device/approve', async (c) => {
      // A form on another site cannot approve on someone's behalf.
      const origin = c.req.header('origin');
      if (
        origin &&
        origin !== new URL(publicUrl).origin &&
        !isLoopback(origin)
      ) {
        throw new HTTPException(403, { message: 'wrong origin' });
      }
      const form = await c.req.parseBody();
      const id = typeof form.request === 'string' ? form.request : '';
      sweep();
      const request = pending.get(id);
      const personId = who(c);
      if (!request || request.code || request.personId !== personId) {
        return c.html(
          page('Deze aanvraag is verlopen', [
            html`<p>Begin opnieuw in de app.</p>`,
          ]),
          410,
        );
      }
      if (form.answer !== 'allow') {
        pending.delete(id);
        return c.html(page('Geweigerd', [html`<p>Er is niets veranderd.</p>`]));
      }
      request.code = randomBytes(32).toString('base64url');
      request.expiresAt = Date.now() + CODE_TTL_MS;
      const target = new URL(request.redirect);
      target.searchParams.set('code', request.code);
      target.searchParams.set('state', request.state);
      return c.redirect(target.toString(), 303);
    })
    .post('/api/login/token', zValidator('json', loginTokenRequest), (c) => {
      const { code, verifier } = c.req.valid('json');
      sweep();
      const entry = [...pending].find(([, p]) => p.code && same(p.code, code));
      if (!entry)
        throw new HTTPException(400, { message: 'invalid or expired code' });
      const [id, request] = entry;
      pending.delete(id);
      const challenge = createHash('sha256')
        .update(verifier)
        .digest('base64url');
      if (!same(challenge, request.challenge)) {
        throw new HTTPException(400, { message: 'invalid or expired code' });
      }
      const owner = person(c.var.db, request.personId)!;
      const rights: Right[] = ['read', 'organize', 'draft', 'send', 'tasks'];
      if (owner.admin) rights.push('admin');
      const { key, token } = createKey(c.var.db, {
        personId: owner.id,
        name: `${title(request.app)} op ${request.device}`,
        rights,
        mailboxIds: null,
        restrictions: {},
      });
      return c.json<LoginTokenResponse>({
        token,
        key,
        person: { id: owner.id, name: owner.name },
      });
    });
}

function isLoopback(value: string) {
  try {
    const url = new URL(value);
    return (
      url.protocol === 'http:' &&
      ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) &&
      url.username === '' &&
      url.password === ''
    );
  } catch {
    return false;
  }
}

function same(a: string, b: string) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

const title = (app: string) => app.charAt(0).toUpperCase() + app.slice(1);

const page = (heading: string, body: unknown[]) =>
  html`<!doctype html>
    <html lang="nl">
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>${heading}</title>
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          margin: 15vh auto;
          max-width: 30rem;
          padding: 0 1.5rem;
          color: #2b2622;
          background: #faf7f2;
        }
        h1 {
          font-size: 1.35rem;
          line-height: 1.3;
        }
        p {
          color: #6b625a;
          line-height: 1.5;
        }
        form {
          display: flex;
          gap: 0.75rem;
          justify-content: flex-end;
          margin-top: 2rem;
        }
        button {
          font: inherit;
          padding: 0.55rem 1.2rem;
          border-radius: 999px;
          border: 0;
          background: #b4532a;
          color: white;
          cursor: pointer;
        }
        button.secondary {
          background: #ebe4da;
          color: #2b2622;
        }
      </style>
      <body>
        <h1>${heading}</h1>
        ${body}
      </body>
    </html>`;
