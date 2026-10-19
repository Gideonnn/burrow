import { createHash, randomBytes } from 'node:crypto';
import { loginTokenResponse, meResponse } from '@burrow/contracts';
import { setPersonEmail } from '@burrow/platform';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';
import { behindCloudflareAccess } from './cloudflareAccess';

const TEAM = 'household.cloudflareaccess.com';
const AUDIENCE = 'burrow-app-aud';

async function household() {
  const h = testHousehold();
  const eva = h.person('Eva');
  setPersonEmail(h.db, eva.id, 'eva@example.com');
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'RS256' };
  const tunnel = behindCloudflareAccess(h.app, {
    db: h.db,
    team: TEAM,
    audience: AUDIENCE,
    keys: createLocalJWKSet({ keys: [jwk] }),
  });
  const login = await new SignJWT({ email: 'eva@example.com' })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
    .setIssuer(`https://${TEAM}`)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(privateKey);
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const query = (overrides: Record<string, string> = {}) =>
    new URLSearchParams({
      app: 'pensieve',
      device: 'MacBook Eva',
      challenge,
      state: 'state-0123456789abcdef',
      redirect: 'http://127.0.0.1:53682/callback',
      ...overrides,
    });
  const asEva = { 'cf-access-jwt-assertion': login };
  const open = (q = query()) =>
    tunnel.request(`/login/device?${q}`, { headers: asEva });
  const approve = (request: string, answer = 'allow', headers = {}) =>
    tunnel.request('/login/device/approve', {
      method: 'POST',
      headers: {
        ...asEva,
        'content-type': 'application/x-www-form-urlencoded',
        ...headers,
      },
      body: new URLSearchParams({ request, answer }).toString(),
    });
  const exchange = (code: string, v = verifier) =>
    tunnel.request('/api/login/token', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code, verifier: v }),
    });
  return { ...h, eva, tunnel, open, approve, exchange, query };
}

const requestId = (html: string) =>
  /name="request" value="([^"]+)"/.exec(html)![1]!;

async function codeFor(h: Awaited<ReturnType<typeof household>>) {
  const page = await h.open();
  const res = await h.approve(requestId(await page.text()));
  expect(res.status).toBe(303);
  const target = new URL(res.headers.get('location')!);
  expect(target.origin).toBe('http://127.0.0.1:53682');
  expect(target.searchParams.get('state')).toBe('state-0123456789abcdef');
  return target.searchParams.get('code')!;
}

describe('logging in a device', () => {
  it('asks the person behind the Access login, then hands the app a device key', async () => {
    const h = await household();
    const page = await h.open();
    expect(page.status).toBe(200);
    expect(await page.clone().text()).toContain(
      'Pensieve op MacBook Eva wil inloggen als Eva',
    );

    const res = await h.exchange(await codeFor(h));
    expect(res.status).toBe(200);
    const { token, key } = loginTokenResponse.parse(await res.json());
    expect(key.name).toBe('Pensieve op MacBook Eva');
    const me = meResponse.parse(await (await h.call(token, '/api/me')).json());
    expect(me.person.name).toBe('Eva');
    expect(me.rights).toContain('admin');
  });

  it('accepts a code once, and only with the verifier of the app that asked', async () => {
    const h = await household();
    const code = await codeFor(h);
    const other = randomBytes(32).toString('base64url');
    expect((await h.exchange(code, other)).status).toBe(400);
    expect((await h.exchange(code)).status).toBe(400);
  });

  it('sends codes only to an address on the Mac itself', async () => {
    const h = await household();
    for (const redirect of [
      'https://evil.example/callback',
      'http://127.0.0.1.evil.example/callback',
      'http://user:pass@127.0.0.1:1/callback',
    ]) {
      expect((await h.open(h.query({ redirect }))).status).toBe(400);
    }
  });

  it('does nothing when the person refuses', async () => {
    const h = await household();
    const page = await h.open();
    const res = await h.approve(requestId(await page.text()), 'deny');
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('Geweigerd');
  });

  it('refuses an approval posted from another site', async () => {
    const h = await household();
    const page = await h.open();
    const res = await h.approve(requestId(await page.text()), 'allow', {
      origin: 'https://evil.example',
    });
    expect(res.status).toBe(403);
  });

  it('needs the Access login: the plain port knows nobody', async () => {
    const h = await household();
    const res = await h.app.request(`/login/device?${h.query()}`);
    expect(res.status).toBe(403);
  });
});
