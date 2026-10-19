import { createHash, randomBytes } from 'node:crypto';
import type { Credentials } from './provider';

export type Fetch = typeof fetch;

export type OAuthProvider = {
  authUrl: string;
  tokenUrl: string;
  scopes: string[];
  extraAuthParams: Record<string, string>;
};

export const GOOGLE: OAuthProvider = {
  authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenUrl: 'https://oauth2.googleapis.com/token',
  // gmail.modify covers reading, labels and sending, but not permanent
  // deletion, which Burrow never does.
  scopes: ['https://www.googleapis.com/auth/gmail.modify'],
  // offline + consent: Google only hands out a refresh token this way.
  extraAuthParams: { access_type: 'offline', prompt: 'consent' },
};

export const MICROSOFT: OAuthProvider = {
  authUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
  tokenUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
  scopes: ['offline_access', 'User.Read', 'Mail.ReadWrite', 'Mail.Send'],
  extraAuthParams: { prompt: 'select_account' },
};

export type OAuthClient = {
  clientId: string;
  clientSecret?: string;
  redirectUri: string;
};

export function pkce() {
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

export function authorizationUrl(
  provider: OAuthProvider,
  client: OAuthClient,
  state: string,
  codeChallenge: string,
): string {
  const url = new URL(provider.authUrl);
  url.search = new URLSearchParams({
    client_id: client.clientId,
    redirect_uri: client.redirectUri,
    response_type: 'code',
    scope: provider.scopes.join(' '),
    state,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    ...provider.extraAuthParams,
  }).toString();
  return url.toString();
}

type TokenResponse = {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
};

async function tokenRequest(
  provider: OAuthProvider,
  client: OAuthClient,
  params: Record<string, string>,
  fetchFn: Fetch,
): Promise<TokenResponse> {
  const body = new URLSearchParams({
    client_id: client.clientId,
    ...(client.clientSecret ? { client_secret: client.clientSecret } : {}),
    ...params,
  });
  const res = await fetchFn(provider.tokenUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!res.ok) {
    throw new Error(
      `token request failed (${res.status}): ${await res.text()}`,
    );
  }
  return (await res.json()) as TokenResponse;
}

export async function exchangeCode(
  provider: OAuthProvider,
  client: OAuthClient,
  code: string,
  codeVerifier: string,
  fetchFn: Fetch = fetch,
): Promise<Credentials & { kind: 'oauth' }> {
  const token = await tokenRequest(
    provider,
    client,
    {
      grant_type: 'authorization_code',
      code,
      code_verifier: codeVerifier,
      redirect_uri: client.redirectUri,
    },
    fetchFn,
  );
  if (!token.refresh_token) {
    throw new Error('the provider returned no refresh token');
  }
  return {
    kind: 'oauth',
    accessToken: token.access_token,
    refreshToken: token.refresh_token,
    expiresAt: Date.now() + token.expires_in * 1000,
  };
}

// Hands out a valid access token, refreshing a minute before it expires, and
// reports new credentials so the server can store them.
export class OAuthSession {
  private refreshing: Promise<void> | undefined;

  constructor(
    private credentials: Credentials & { kind: 'oauth' },
    private readonly provider: OAuthProvider,
    private readonly client: OAuthClient,
    private readonly onRefresh: (credentials: Credentials) => void,
    private readonly fetchFn: Fetch = fetch,
  ) {}

  async accessToken({ force = false } = {}): Promise<string> {
    if (force || this.credentials.expiresAt - 60_000 < Date.now()) {
      this.refreshing ??= this.refresh().finally(() => {
        this.refreshing = undefined;
      });
      await this.refreshing;
    }
    return this.credentials.accessToken;
  }

  private async refresh() {
    const token = await tokenRequest(
      this.provider,
      this.client,
      {
        grant_type: 'refresh_token',
        refresh_token: this.credentials.refreshToken,
      },
      this.fetchFn,
    );
    this.credentials = {
      kind: 'oauth',
      accessToken: token.access_token,
      // Microsoft rotates refresh tokens; Google keeps the old one.
      refreshToken: token.refresh_token ?? this.credentials.refreshToken,
      expiresAt: Date.now() + token.expires_in * 1000,
    };
    this.onRefresh(this.credentials);
  }
}

// Authenticated JSON calls with one retry after a forced refresh on 401.
export async function bearerJson<T>(
  session: Pick<OAuthSession, 'accessToken'>,
  url: string,
  init: RequestInit = {},
  fetchFn: Fetch = fetch,
): Promise<T> {
  const call = async (force: boolean) =>
    fetchFn(url, {
      ...init,
      headers: {
        ...init.headers,
        authorization: `Bearer ${await session.accessToken({ force })}`,
        ...(init.body ? { 'content-type': 'application/json' } : {}),
      },
    });
  let res = await call(false);
  if (res.status === 401) res = await call(true);
  if (!res.ok)
    throw new HttpError(
      res.status,
      `${init.method ?? 'GET'} ${url}: ${res.status} ${await res.text()}`,
    );
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}
