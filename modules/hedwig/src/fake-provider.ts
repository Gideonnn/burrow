import type { ServerOp } from '@burrow/contracts';
import type {
  BackfillPage,
  MailProviderClient,
  OutgoingMessage,
  ProviderAttachment,
  ProviderMessage,
  SyncResult,
} from './provider';
import { applyOps } from './server-ops';

// A file for a fake message; size defaults to the data's length, so a test can
// claim a huge file without allocating it.
export type FakeAttachment = Partial<Omit<ProviderAttachment, 'name'>> & {
  name: string;
  data: Uint8Array | string;
};

type FakeMessage = Partial<ProviderMessage> & {
  subject: string;
  attachments?: FakeAttachment[];
};

// An in-memory provider for tests: deliver() puts a message in its inbox, the
// next sync() returns what changed since the cursor. keep() adds mail that was
// there before, which only backfill() returns.
export class FakeProvider implements MailProviderClient {
  readonly messages = new Map<string, ProviderMessage>();
  readonly applied: { providerId: string; ops: ServerOp[] }[] = [];
  readonly sent: OutgoingMessage[] = [];
  readonly files = new Map<
    string,
    { meta: ProviderAttachment; data: Uint8Array }[]
  >();
  private changes: { version: number; id: string }[] = [];
  private version = 0;
  failNextApply = false;
  pageSize = 100;
  backfillCalls = 0;

  deliver(partial: FakeMessage): ProviderMessage {
    const message = this.keep(partial);
    this.changes.push({ version: ++this.version, id: message.providerId });
    return message;
  }

  keep({ attachments = [], ...partial }: FakeMessage): ProviderMessage {
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
      hasAttachments: attachments.length > 0,
      bodyText: partial.subject,
      bodyHtml: null,
      headers: {},
      ...partial,
    };
    this.messages.set(message.providerId, message);
    this.files.set(
      message.providerId,
      attachments.map((a, i) => {
        const data =
          typeof a.data === 'string'
            ? new TextEncoder().encode(a.data)
            : a.data;
        return {
          meta: {
            id: a.id ?? `att${i + 1}`,
            name: a.name,
            contentType: a.contentType ?? 'application/octet-stream',
            size: a.size ?? data.byteLength,
            inline: a.inline ?? false,
          },
          data,
        };
      }),
    );
    return message;
  }

  async address(): Promise<string> {
    return 'owner@example.com';
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

  async backfill(page: string | null): Promise<BackfillPage> {
    this.backfillCalls++;
    const start = Number(page ?? 0);
    const all = [...this.messages.values()]
      .filter((m) => m.folder !== 'spam' && m.folder !== 'trash')
      .sort((a, b) => b.receivedAt.getTime() - a.receivedAt.getTime());
    const end = start + this.pageSize;
    return {
      messages: all.slice(start, end),
      next: end < all.length ? String(end) : null,
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

  async attachments(providerId: string): Promise<ProviderAttachment[]> {
    if (!this.messages.has(providerId))
      throw new Error(`unknown message ${providerId}`);
    return (this.files.get(providerId) ?? []).map((f) => ({ ...f.meta }));
  }

  async attachment(
    providerId: string,
    attachmentId: string,
  ): Promise<Uint8Array> {
    const file = this.files
      .get(providerId)
      ?.find((f) => f.meta.id === attachmentId);
    if (!file) throw new Error(`unknown attachment ${attachmentId}`);
    return file.data;
  }
}
