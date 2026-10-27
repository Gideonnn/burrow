import type { MailProvider } from '@burrow/contracts';
import type { Db, SecretBox } from '@burrow/platform';
import { and, eq, isNull } from 'drizzle-orm';
import { DemoProvider } from '../demo-provider';
import { GmailClient } from '../gmail';
import { GraphClient } from '../graph';
import { JmapClient } from '../jmap';
import {
  exchangeCode,
  type Fetch,
  GOOGLE,
  MICROSOFT,
  type OAuthClient,
  type OAuthProvider,
  OAuthSession,
} from '../oauth';
import type { Credentials, MailProviderClient } from '../provider';
import type { ClientFor, MailboxRow } from './mail-service';
import { mailboxes } from './schema';

export type OAuthAppConfig = { clientId: string; clientSecret?: string };

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
  private readonly demos = new Map<string, DemoProvider>();
  // Called when a mailbox starts or stops needing a new login.
  onReconnectChanged?: (mailboxId: string) => void;

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
    if (credentials.kind === 'demo') {
      // Cached so a demo session keeps its state between requests.
      let demo = this.demos.get(mailbox.id);
      if (!demo) {
        demo = new DemoProvider(credentials.seed, mailbox.address);
        this.demos.set(mailbox.id, demo);
      }
      return demo;
    }
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
      () => this.markReconnectNeeded(mailbox.id),
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
      const row = db
        .update(mailboxes)
        .set({ credentials: sealed, reconnectNeededAt: null })
        .where(eq(mailboxes.id, existing.id))
        .returning()
        .get();
      if (existing.reconnectNeededAt) this.onReconnectChanged?.(existing.id);
      return row;
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

  private markReconnectNeeded(mailboxId: string) {
    if (mailboxId === 'probe') return;
    const { changes } = this.options.db
      .update(mailboxes)
      .set({ reconnectNeededAt: new Date() })
      .where(
        and(eq(mailboxes.id, mailboxId), isNull(mailboxes.reconnectNeededAt)),
      )
      .run();
    if (changes) this.onReconnectChanged?.(mailboxId);
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
    case 'microsoft':
      return (session, fetchFn) =>
        new GraphClient(session as OAuthSession, fetchFn);
    case 'fastmail':
      return (token, fetchFn) => new JmapClient(token as string, fetchFn);
    default:
      return () => {
        throw new Error(`no client for ${provider} yet`);
      };
  }
}
