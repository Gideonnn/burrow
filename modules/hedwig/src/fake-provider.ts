import type { ServerOp } from '@burrow/contracts';
import type {
  MailProviderClient,
  OutgoingMessage,
  ProviderMessage,
  SyncResult,
} from './provider';
import { applyOps } from './server-ops';

// An in-memory provider for tests: deliver() puts a message in its inbox, the
// next sync() returns what changed since the cursor.
export class FakeProvider implements MailProviderClient {
  readonly messages = new Map<string, ProviderMessage>();
  readonly applied: { providerId: string; ops: ServerOp[] }[] = [];
  readonly sent: OutgoingMessage[] = [];
  private changes: { version: number; id: string }[] = [];
  private version = 0;
  failNextApply = false;

  deliver(
    partial: Partial<ProviderMessage> & { subject: string },
  ): ProviderMessage {
    const message: ProviderMessage = {
      providerId: `m${this.messages.size + 1}`,
      threadId: null,
      from: { name: 'Someone', email: 'someone@example.com' },
      to: [{ email: 'owner@example.com' }],
      cc: [],
      snippet: partial.subject,
      receivedAt: new Date('2026-10-19T08:00:00Z'),
      folder: 'inbox',
      unread: true,
      flagged: false,
      labels: [],
      hasAttachments: false,
      bodyText: partial.subject,
      bodyHtml: null,
      headers: {},
      ...partial,
    };
    this.messages.set(message.providerId, message);
    this.changes.push({ version: ++this.version, id: message.providerId });
    return message;
  }

  async sync(cursor: string | null): Promise<SyncResult> {
    const since = cursor === null ? 0 : Number(cursor);
    const ids = new Set(
      this.changes.filter((c) => c.version > since).map((c) => c.id),
    );
    return {
      upserts: [...ids].flatMap((id) => {
        const m = this.messages.get(id);
        return m ? [m] : [];
      }),
      removed: [...ids].filter((id) => !this.messages.has(id)),
      cursor: String(this.version),
    };
  }

  async apply(providerId: string, ops: ServerOp[]): Promise<void> {
    if (this.failNextApply) {
      this.failNextApply = false;
      throw new Error('provider unavailable');
    }
    const m = this.messages.get(providerId);
    if (!m) throw new Error(`unknown message ${providerId}`);
    this.messages.set(providerId, { ...m, ...applyOps(m, ops) });
    this.applied.push({ providerId, ops });
  }

  async send(message: OutgoingMessage): Promise<void> {
    this.sent.push(message);
  }
}
