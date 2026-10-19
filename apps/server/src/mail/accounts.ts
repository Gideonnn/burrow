import type { MailProvider } from '@burrow/contracts';
import {
  type Credentials,
  exchangeCode,
  type Fetch,
  GmailClient,
  GOOGLE,
  MICROSOFT,
  type MailProviderClient,
  type OAuthClient,
  type OAuthProvider,
  OAuthSession,
} from '@burrow/hedwig';
import { and, eq } from 'drizzle-orm';
import type { OAuthAppConfig } from '../config';
import type { SecretBox } from '../crypto/secretBox';
import type { Db } from '../db/client';
import { mailboxes } from '../db/schema';
import type { ClientFor, MailboxRow } from './service';

export type OAuthMailProvider = Extract<MailProvider, 'gmail' | 'microsoft'>;

export type AccountsOptions = {
  db: Db;
  box: SecretBox;
  publicUrl: string;
  apps: Partial<Record<OAuthMailProvider, OAuthAppConfig>>;
  fetchFn?: Fetch;
  // Provider client constructors, replaceable in tests.
  clients?: Partial<
    Record<
      MailProvider,
      (session: OAuthSession | string, fetchFn: Fetch) => MailProviderClient
    >
  >;
};

const OAUTH: Record<OAuthMailProvider, OAuthProvider> = {
  gmail: GOOGLE,
  microsoft: MICROSOFT,
};

// Turns a stored mailbox into a live provider client, and stores mailboxes
// connected through OAuth. Credentials are only ever decrypted here.
export class Accounts {
  private readonly fetchFn: Fetch;

  constructor(private readonly options: AccountsOptions) {
    this.fetchFn = options.fetchFn ?? fetch;
  }

  get publicUrl(): string {
    return this.options.publicUrl;
  }

  exchange(provider: OAuthMailProvider, code: string, verifier: string) {
    return exchangeCode(
      OAUTH[provider],
      this.oauthClient(provider),
      code,
      verifier,
      this.fetchFn,
    );
  }

  oauthClient(provider: OAuthMailProvider): OAuthClient {
    const app = this.options.apps[provider];
    if (!app) throw new Error(`${provider} is not configured on this server`);
    return { ...app, redirectUri: `${this.options.publicUrl}/oauth/callback` };
  }

  oauthProvider(provider: OAuthMailProvider): OAuthProvider {
    return OAUTH[provider];
  }

  isConfigured(provider: OAuthMailProvider): boolean {
    return Boolean(this.options.apps[provider]);
  }

  readonly clientFor: ClientFor = (mailbox) => {
    const credentials = this.options.box.open<Credentials>(mailbox.credentials);
    const make =
      this.options.clients?.[mailbox.provider] ??
      defaultClient(mailbox.provider);
    if (credentials.kind === 'token')
      return make(credentials.token, this.fetchFn);
    const provider = mailbox.provider as OAuthMailProvider;
    const session = new OAuthSession(
      credentials,
      OAUTH[provider],
      this.oauthClient(provider),
      (next) => this.saveCredentials(mailbox.id, next),
      this.fetchFn,
    );
    return make(session, this.fetchFn);
  };

  // Builds a client for credentials that are not stored yet, to ask the
  // provider which address they belong to.
  probe(provider: MailProvider, credentials: Credentials): MailProviderClient {
    return this.clientFor({
      id: 'probe',
      provider,
      credentials: this.options.box.seal(credentials),
    } as MailboxRow);
  }

  // Connecting the same address again for the same person replaces its
  // credentials instead of creating a duplicate mailbox.
  upsertMailbox(input: {
    ownerId: string;
    provider: MailProvider;
    address: string;
    credentials: Credentials;
  }): MailboxRow {
    const { db, box } = this.options;
    const sealed = box.seal(input.credentials);
    const existing = db
      .select()
      .from(mailboxes)
      .where(
        and(
          eq(mailboxes.ownerId, input.ownerId),
          eq(mailboxes.provider, input.provider),
          eq(mailboxes.address, input.address),
        ),
      )
      .get();
    if (existing) {
      return db
        .update(mailboxes)
        .set({ credentials: sealed })
        .where(eq(mailboxes.id, existing.id))
        .returning()
        .get();
    }
    return db
      .insert(mailboxes)
      .values({
        ownerId: input.ownerId,
        provider: input.provider,
        address: input.address,
        name: input.address,
        credentials: sealed,
      })
      .returning()
      .get();
  }

  private saveCredentials(mailboxId: string, credentials: Credentials) {
    if (mailboxId === 'probe') return;
    this.options.db
      .update(mailboxes)
      .set({ credentials: this.options.box.seal(credentials) })
      .where(eq(mailboxes.id, mailboxId))
      .run();
  }
}

function defaultClient(
  provider: MailProvider,
): (session: OAuthSession | string, fetchFn: Fetch) => MailProviderClient {
  switch (provider) {
    case 'gmail':
      return (session, fetchFn) =>
        new GmailClient(session as OAuthSession, fetchFn);
    default:
      return () => {
        throw new Error(`no client for ${provider} yet`);
      };
  }
}
