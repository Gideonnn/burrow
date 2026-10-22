import type {
  AttachmentSummary,
  MessageDetail,
  MessageFacts,
  MessageSummary,
  SendRequest,
  ServerOp,
} from '@burrow/contracts';
import type { Db, EventBus } from '@burrow/platform';
import { and, eq, inArray } from 'drizzle-orm';
import type {
  MailProviderClient,
  ProviderAttachment,
  ProviderMessage,
} from '../provider';
import { applyOps } from '../server-ops';
import { mailboxes, messages } from './schema';

export type MailboxRow = typeof mailboxes.$inferSelect;
export type MessageRow = typeof messages.$inferSelect;
export type ClientFor = (mailbox: MailboxRow) => MailProviderClient;

export class MailError extends Error {}
export class MailNotFoundError extends MailError {}
export class AttachmentTooLargeError extends MailError {}

// Attachments pass through the server's memory on their way to the client.
const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;

export type MailEvent = {
  type: 'message.new' | 'message.changed' | 'message.removed';
  mailboxId: string;
  messageId: string;
};

export class MailService {
  // Mailboxes a sync or backfill is busy with; one at a time per mailbox, so
  // two clients never refresh the same OAuth tokens at once.
  private readonly busy = new Set<string>();
  // Called with every message stored or changed by sync and backfill, after
  // the commit; the facts rules run here.
  onStored?: (messageIds: string[]) => void;

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
    if (this.busy.has(mailboxId)) return [];
    this.busy.add(mailboxId);
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
      this.onStored?.(
        pending
          .filter((e) => e.type !== 'message.removed')
          .map((e) => e.messageId),
      );
      return arrived;
    } finally {
      this.busy.delete(mailboxId);
    }
  }

  // Brings in one page of older mail, so search covers the whole mailbox.
  // True while there is more. Old mail is never sorted and announces nothing;
  // what sync already stored stays as it is.
  async backfill(mailboxId: string): Promise<boolean> {
    const box = this.mailbox(mailboxId);
    if (!box || box.backfilledAt) return false;
    if (this.busy.has(mailboxId)) return true;
    this.busy.add(mailboxId);
    try {
      const page = await this.clientFor(box).backfill(box.backfillCursor);
      const now = new Date();
      const stored: string[] = [];
      this.db.transaction((tx) => {
        for (const m of page.messages) {
          const row = tx
            .insert(messages)
            .values({
              mailboxId: box.id,
              providerId: m.providerId,
              ...columnsFrom(m),
              triagedAt: now,
            })
            .onConflictDoNothing()
            .returning({ id: messages.id })
            .get();
          if (row) stored.push(row.id);
        }
        tx.update(mailboxes)
          .set(
            page.next
              ? { backfillCursor: page.next }
              : { backfillCursor: null, backfilledAt: now },
          )
          .where(eq(mailboxes.id, box.id))
          .run();
      });
      this.onStored?.(stored);
      return page.next !== null;
    } finally {
      this.busy.delete(mailboxId);
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

  // Fetched from the provider every time; Burrow does not keep attachments.
  async attachments(messageId: string): Promise<AttachmentSummary[]> {
    const { row, box } = this.located(messageId);
    const list = await this.clientFor(box).attachments(row.providerId);
    return list.map(toAttachmentSummary);
  }

  async attachment(
    messageId: string,
    attachmentId: string,
  ): Promise<{ meta: AttachmentSummary; data: Uint8Array }> {
    const { row, box } = this.located(messageId);
    const client = this.clientFor(box);
    const found = (await client.attachments(row.providerId)).find(
      (a) => a.id === attachmentId,
    );
    if (!found) throw new MailNotFoundError('unknown attachment');
    const tooLarge = () =>
      new AttachmentTooLargeError(
        `${found.name} is larger than 25 MB; open it in the webmail`,
      );
    if (found.size > MAX_ATTACHMENT_BYTES) throw tooLarge();
    const data = await client.attachment(row.providerId, attachmentId);
    if (data.byteLength > MAX_ATTACHMENT_BYTES) throw tooLarge();
    // Graph's size counts the attachment's metadata too; the bytes are exact.
    return {
      meta: { ...toAttachmentSummary(found), size: data.byteLength },
      data,
    };
  }

  private located(messageId: string) {
    const row = this.message(messageId);
    if (!row) throw new MailNotFoundError('unknown message');
    return { row, box: this.mailbox(row.mailboxId)! };
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

function toAttachmentSummary(a: ProviderAttachment): AttachmentSummary {
  return {
    id: a.id,
    name: a.name,
    contentType: a.contentType,
    size: Math.max(0, Math.round(a.size)),
    inline: a.inline,
  };
}

export function toSummary(
  row: MessageRow,
  facts: MessageFacts | null = null,
): MessageSummary {
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
    facts,
  };
}

export function toDetail(
  row: MessageRow,
  facts: MessageFacts | null = null,
): MessageDetail {
  return {
    ...toSummary(row, facts),
    cc: row.cc,
    bodyText: row.bodyText,
    bodyHtml: row.bodyHtml,
  };
}
