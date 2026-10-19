import { meResponse } from '@burrow/contracts';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { describe, expect, it } from 'vitest';
import { setPersonEmail } from '../access/service';
import { testHousehold } from '../testing';
import { behindCloudflareAccess } from './cloudflareAccess';

const TEAM = 'household.cloudflareaccess.com';
const AUDIENCE = 'burrow-app-aud';

async function signer() {
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'RS256' };
  const sign = (
    claims: Record<string, unknown>,
    { audience = AUDIENCE, issuer = `https://${TEAM}`, expires = '5m' } = {},
  ) =>
    new SignJWT(claims)
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(issuer)
      .setAudience(audience)
      .setIssuedAt()
      .setExpirationTime(expires)
      .sign(privateKey);
  return { keys: createLocalJWKSet({ keys: [jwk] }), sign };
}

async function household() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  setPersonEmail(h.db, gideon.id, 'Gideon@Example.com');
  const issuer = await signer();
  const tunnel = behindCloudflareAccess(h.app, {
    db: h.db,
    team: TEAM,
    audience: AUDIENCE,
    keys: issuer.keys,
  });
  const visit = (path: string, token?: string, headers = {}) =>
    tunnel.request(path, {
      headers: token
        ? { 'cf-access-jwt-assertion': token, ...headers }
        : headers,
    });
  return { ...h, gideon, tunnel, visit, ...issuer };
}

describe('the tunnel behind Cloudflare Access', () => {
  it('admits a household member logged in through Access', async () => {
    const h = await household();
    const res = await h.visit(
      '/health',
      await h.sign({ email: 'gideon@example.com' }),
    );
    expect(res.status).toBe(200);
  });

  it('turns away a request without an Access token', async () => {
    const h = await household();
    expect((await h.visit('/health')).status).toBe(403);
  });

  it('turns away a token from another key, audience, team or one that expired', async () => {
    const h = await household();
    const other = await signer();
    const claims = { email: 'gideon@example.com' };
    for (const token of [
      await other.sign(claims),
      await h.sign(claims, { audience: 'another-app' }),
      await h.sign(claims, { issuer: 'https://intruder.cloudflareaccess.com' }),
      await h.sign(claims, { expires: '-1m' }),
    ]) {
      expect((await h.visit('/health', token)).status).toBe(403);
    }
  });

  it('turns away a valid login that belongs to no person in the household', async () => {
    const h = await household();
    const res = await h.visit(
      '/health',
      await h.sign({ email: 'stranger@example.com' }),
    );
    expect(res.status).toBe(403);
  });

  it('lets clients reach the API with only their key, as Access lets /api through', async () => {
    const h = await household();
    const token = h.key(h.gideon.id, ['read']);
    const me = meResponse.parse(
      await (
        await h.visit('/api/me', undefined, {
          authorization: `Bearer ${token}`,
        })
      ).json(),
    );
    expect(me.person.name).toBe('Gideon');
  });

  it('still asks for an API key on the API, even with a login', async () => {
    const h = await household();
    const login = await h.sign({ email: 'gideon@example.com' });
    expect((await h.visit('/api/me', login)).status).toBe(401);
    expect((await h.visit('/api/me')).status).toBe(401);
  });

  it('does not let a path that only looks like the API past the login', async () => {
    const h = await household();
    for (const path of ['/apix', '/api/../health', '/%61pi/../health']) {
      expect((await h.visit(path)).status).not.toBe(200);
    }
  });
});
