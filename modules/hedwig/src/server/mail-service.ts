import type {
  MessageDetail,
  MessageSummary,
  SendRequest,
  ServerOp,
} from '@burrow/contracts';
import type { Db, EventBus } from '@burrow/platform';
import { and, eq, inArray } from 'drizzle-orm';
import type { MailProviderClient, ProviderMessage } from '../provider';
import { applyOps } from '../server-ops';
import { mailboxes, messages } from './schema';

export type MailboxRow = typeof mailboxes.$inferSelect;
export type MessageRow = typeof messages.$inferSelect;
export type ClientFor = (mailbox: MailboxRow) => MailProviderClient;

export class MailError extends Error {}

export type MailEvent = {
  type: 'message.new' | 'message.changed' | 'message.removed';
  mailboxId: string;
  messageId: string;
};

export class MailService {
  private readonly syncing = new Set<string>();

  constructor(
    private readonly db: Db,
    private readonly clientFor: ClientFor,
    private readonly events: EventBus,
  ) {}

  mailbox(id: string): MailboxRow | undefined {
    return this.db.select().from(mailboxes).where(eq(mailboxes.id, id)).get();
  }

  allMailboxes(): MailboxRow[] {
    return this.db.select().from(mailboxes).all();
  }

  message(id: string): MessageRow | undefined {
    return this.db.select().from(messages).where(eq(messages.id, id)).get();
  }

  // Pulls changes from the provider into the local store. Returns the ids of
  // messages that arrived in the inbox, for triage.
  async sync(mailboxId: string): Promise<string[]> {
    if (this.syncing.has(mailboxId)) return [];
    this.syncing.add(mailboxId);
    try {
      const box = this.mailbox(mailboxId);
      if (!box) throw new MailError('unknown mailbox');
      const result = await this.clientFor(box).sync(box.syncCursor);
      const arrived: string[] = [];
      // Emitted after the commit, so a rolled-back sync announces nothing.
      const pending: MailEvent[] = [];

      this.db.transaction((tx) => {
        for (const m of result.upserts) {
          const existing = tx
            .select({ id: messages.id })
            .from(messages)
            .where(
              and(
                eq(messages.mailboxId, box.id),
                eq(messages.providerId, m.providerId),
              ),
            )
            .get();
          if (existing) {
            tx.update(messages)
              .set(columnsFrom(m))
              .where(eq(messages.id, existing.id))
              .run();
            pending.push({
              type: 'message.changed',
              mailboxId: box.id,
              messageId: existing.id,
            });
          } else {
            const row = tx
              .insert(messages)
              .values({
                mailboxId: box.id,
                providerId: m.providerId,
                ...columnsFrom(m),
              })
              .returning({ id: messages.id })
              .get();
            if (m.folder === 'inbox') arrived.push(row.id);
            pending.push({
              type: 'message.new',
              mailboxId: box.id,
              messageId: row.id,
            });
          }
        }
        if (result.removed.length) {
          const gone = tx
            .delete(messages)
            .where(
              and(
                eq(messages.mailboxId, box.id),
                inArray(messages.providerId, result.removed),
              ),
            )
            .returning({ id: messages.id })
            .all();
          for (const { id } of gone) {
            pending.push({
              type: 'message.removed',
              mailboxId: box.id,
              messageId: id,
            });
          }
        }
        tx.update(mailboxes)
          .set({ syncCursor: result.cursor })
          .where(eq(mailboxes.id, box.id))
          .run();
      });
      for (const event of pending) this.emit(event);
      return arrived;
    } finally {
      this.syncing.delete(mailboxId);
    }
  }

  // Applies operations at the provider first; the local copy only changes
  // once the provider accepted them, so both never disagree for long.
  async apply(messageId: string, ops: ServerOp[]): Promise<MessageRow> {
    const row = this.message(messageId);
    if (!row) throw new MailError('unknown message');
    const box = this.mailbox(row.mailboxId)!;
    await this.clientFor(box).apply(row.providerId, ops);
    const next = applyOps(row, ops);
    const updated = this.db
      .update(messages)
      .set(next)
      .where(eq(messages.id, row.id))
      .returning()
      .get();
    this.emit({
      type: 'message.changed',
      mailboxId: box.id,
      messageId: row.id,
    });
    return updated;
  }

  // Only keys that see the mailbox hear about its messages.
  private emit(data: MailEvent) {
    this.events.emit({
      data,
      visibleTo: (access) => access.mailboxIds.includes(data.mailboxId),
    });
  }

  async send(request: SendRequest): Promise<void> {
    const box = this.mailbox(request.mailboxId);
    if (!box) throw new MailError('unknown mailbox');
    const original = request.inReplyTo
      ? this.message(request.inReplyTo)
      : undefined;
    if (request.inReplyTo && original?.mailboxId !== box.id) {
      throw new MailError(
        'can only reply from the mailbox that received the message',
      );
    }
    await this.clientFor(box).send({
      from: { name: box.name, email: box.address },
      to: request.to,
      cc: request.cc,
      subject: request.subject,
      body: request.body,
      replyTo: original && {
        providerId: original.providerId,
        threadId: original.threadId,
        headers: original.headers,
      },
    });
  }
}

function columnsFrom(m: ProviderMessage) {
  return {
    threadId: m.threadId,
    from: m.from,
    to: m.to,
    cc: m.cc,
    subject: m.subject,
    snippet: m.snippet,
    bodyText: m.bodyText,
    bodyHtml: m.bodyHtml,
    receivedAt: m.receivedAt,
    folder: m.folder,
    unread: m.unread,
    flagged: m.flagged,
    labels: m.labels,
    hasAttachments: m.hasAttachments,
    headers: m.headers,
  };
}

export function toSummary(row: MessageRow): MessageSummary {
  return {
    id: row.id,
    mailboxId: row.mailboxId,
    threadId: row.threadId,
    from: row.from,
    to: row.to,
    subject: row.subject,
    snippet: row.snippet,
    receivedAt: row.receivedAt.toISOString(),
    folder: row.folder,
    unread: row.unread,
    flagged: row.flagged,
    labels: row.labels,
    hasAttachments: row.hasAttachments,
  };
}

export function toDetail(row: MessageRow): MessageDetail {
  return {
    ...toSummary(row),
    cc: row.cc,
    bodyText: row.bodyText,
    bodyHtml: row.bodyHtml,
  };
}
