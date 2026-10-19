import { describe, expect, it } from 'vitest';
import {
  authorizationUrl,
  exchangeCode,
  GOOGLE,
  OAuthSession,
  pkce,
} from './oauth';
import type { Credentials } from './provider';

const client = {
  clientId: 'cid',
  clientSecret: 'secret',
  redirectUri: 'https://burrow.example/oauth/callback',
};

function tokenEndpoint(responses: object[]) {
  const calls: URLSearchParams[] = [];
  const fetchFn = (async (_url: string, init: RequestInit) => {
    calls.push(new URLSearchParams(String(init.body)));
    return new Response(JSON.stringify(responses.shift()), { status: 200 });
  }) as unknown as typeof fetch;
  return { fetchFn, calls };
}

describe('OAuth', () => {
  it('builds a PKCE authorization URL that asks for offline access', () => {
    const { challenge } = pkce();
    const url = new URL(authorizationUrl(GOOGLE, client, 'state-1', challenge));
    expect(url.searchParams.get('code_challenge_method')).toBe('S256');
    expect(url.searchParams.get('access_type')).toBe('offline');
    expect(url.searchParams.get('state')).toBe('state-1');
  });

  it('exchanges a code with the verifier and keeps the refresh token', async () => {
    const { fetchFn, calls } = tokenEndpoint([
      { access_token: 'at', refresh_token: 'rt', expires_in: 3600 },
    ]);
    const creds = await exchangeCode(
      GOOGLE,
      client,
      'code',
      'verifier',
      fetchFn,
    );
    expect(creds).toMatchObject({ accessToken: 'at', refreshToken: 'rt' });
    expect(calls[0]?.get('code_verifier')).toBe('verifier');
  });

  it('refuses a grant without a refresh token, which would stop working in an hour', async () => {
    const { fetchFn } = tokenEndpoint([
      { access_token: 'at', expires_in: 3600 },
    ]);
    await expect(
      exchangeCode(GOOGLE, client, 'code', 'v', fetchFn),
    ).rejects.toThrow(/refresh token/);
  });

  it('refreshes an expiring token once and reports the new credentials', async () => {
    const { fetchFn, calls } = tokenEndpoint([
      { access_token: 'new', expires_in: 3600 },
    ]);
    const saved: Credentials[] = [];
    const session = new OAuthSession(
      {
        kind: 'oauth',
        accessToken: 'old',
        refreshToken: 'rt',
        expiresAt: Date.now() + 10_000,
      },
      GOOGLE,
      client,
      (c) => saved.push(c),
      fetchFn,
    );
    const [a, b] = await Promise.all([
      session.accessToken(),
      session.accessToken(),
    ]);
    expect([a, b]).toEqual(['new', 'new']);
    expect(calls).toHaveLength(1);
    expect(saved[0]).toMatchObject({ accessToken: 'new', refreshToken: 'rt' });
  });
});
