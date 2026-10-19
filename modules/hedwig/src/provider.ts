import type {
  Address,
  MailFolder,
  SendRequest,
  ServerOp,
} from '@burrow/contracts';

// A message as a provider client reports it, before the server stores it.
export type ProviderMessage = {
  providerId: string;
  threadId: string | null;
  from: Address;
  to: Address[];
  cc: Address[];
  subject: string;
  snippet: string;
  receivedAt: Date;
  folder: MailFolder;
  unread: boolean;
  flagged: boolean;
  labels: string[];
  hasAttachments: boolean;
  bodyText: string | null;
  bodyHtml: string | null;
  // Signals for triage: authentication results, List-Unsubscribe and the
  // Message-ID used for threading replies.
  headers: {
    messageId?: string;
    references?: string;
    authenticationResults?: string;
    listUnsubscribe?: string;
  };
};

export type SyncResult = {
  upserts: ProviderMessage[];
  removed: string[];
  cursor: string;
};

export type OutgoingMessage = Omit<SendRequest, 'mailboxId' | 'inReplyTo'> & {
  from: Address;
  replyTo?: Pick<ProviderMessage, 'providerId' | 'threadId' | 'headers'>;
};

// One implementation per provider API (Gmail API, Microsoft Graph, Fastmail
// JMAP). IMAP is deliberately not supported; see the architecture topic.
export interface MailProviderClient {
  // The address the credentials belong to, used when connecting an account.
  address(): Promise<string>;
  // Without a cursor: the recent inbox, plus a cursor for the next call.
  sync(cursor: string | null): Promise<SyncResult>;
  apply(providerId: string, ops: ServerOp[]): Promise<void>;
  send(message: OutgoingMessage): Promise<void>;
}

// Credentials as stored (encrypted) per mailbox.
export type Credentials =
  | {
      kind: 'oauth';
      accessToken: string;
      refreshToken: string;
      expiresAt: number;
    }
  | { kind: 'token'; token: string };
