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
  replyTo: Address[];
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

// A file on a message, listed without its content. The id stays the same
// between calls for the same message, so it can go into a URL.
export type ProviderAttachment = {
  id: string;
  name: string;
  contentType: string;
  size: number;
  inline: boolean;
};

export type SyncResult = {
  upserts: ProviderMessage[];
  removed: string[];
  cursor: string;
};

export type BackfillPage = {
  messages: ProviderMessage[];
  // Where the next, older page starts; null once the archive is in.
  next: string | null;
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
  // Older mail in every folder but spam and trash where the provider allows,
  // newest first, one page per call; null asks for the first page.
  backfill(page: string | null): Promise<BackfillPage>;
  apply(providerId: string, ops: ServerOp[]): Promise<void>;
  send(message: OutgoingMessage): Promise<void>;
  // Fetched from the provider on demand; Burrow never stores attachments.
  attachments(providerId: string): Promise<ProviderAttachment[]>;
  attachment(providerId: string, attachmentId: string): Promise<Uint8Array>;
}

// Credentials as stored (encrypted) per mailbox.
export type Credentials =
  | {
      kind: 'oauth';
      accessToken: string;
      refreshToken: string;
      expiresAt: number;
    }
  | { kind: 'token'; token: string }
  // Invented mail for development and demos (cli seed-demo); never a real account.
  | { kind: 'demo'; seed: string };
