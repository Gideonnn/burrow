import type { Mailbox, Message } from '@burrow/contracts';
import type { ServerOp } from './server-ops';

export type SyncResult = {
  messages: Message[];
  cursor: string;
};

// One implementation per provider API (Gmail API, Microsoft Graph, Fastmail
// JMAP). IMAP is deliberately not supported; see the architecture topic.
export interface MailProviderClient {
  readonly mailbox: Mailbox;
  sync(cursor: string | undefined): Promise<SyncResult>;
  apply(providerMessageId: string, ops: ServerOp[]): Promise<void>;
}
