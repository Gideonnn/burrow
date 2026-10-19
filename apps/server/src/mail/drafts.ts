import type { CreateDraftRequest, Draft } from '@burrow/contracts';
import { and, desc, eq, inArray } from 'drizzle-orm';
import type { Access } from '../auth/access';
import type { Db } from '../db/client';
import { drafts, messages } from '../db/schema';

export class DraftError extends Error {}

export function createDraft(
  db: Db,
  access: Access,
  request: CreateDraftRequest,
): Draft {
  if (!access.mailboxIds.includes(request.mailboxId))
    throw new DraftError('not found');
  if (request.inReplyTo) {
    const original = db
      .select()
      .from(messages)
      .where(eq(messages.id, request.inReplyTo))
      .get();
    if (original?.mailboxId !== request.mailboxId) {
      throw new DraftError(
        'a reply must be drafted in the mailbox that received the message',
      );
    }
  }
  const row = db
    .insert(drafts)
    .values({
      mailboxId: request.mailboxId,
      createdBy: access.keyName,
      inReplyTo: request.inReplyTo ?? null,
      to: request.to,
      cc: request.cc,
      subject: request.subject,
      body: request.body,
    })
    .returning()
    .get();
  return toDraft(row);
}

export function listDrafts(db: Db, access: Access): Draft[] {
  if (!access.mailboxIds.length) return [];
  return db
    .select()
    .from(drafts)
    .where(inArray(drafts.mailboxId, [...access.mailboxIds]))
    .orderBy(desc(drafts.createdAt))
    .all()
    .map(toDraft);
}

export function deleteDraft(db: Db, access: Access, id: string): boolean {
  if (!access.mailboxIds.length) return false;
  return (
    db
      .delete(drafts)
      .where(
        and(
          eq(drafts.id, id),
          inArray(drafts.mailboxId, [...access.mailboxIds]),
        ),
      )
      .returning()
      .all().length > 0
  );
}

function toDraft(row: typeof drafts.$inferSelect): Draft {
  return {
    id: row.id,
    mailboxId: row.mailboxId,
    createdBy: row.createdBy,
    inReplyTo: row.inReplyTo,
    to: row.to,
    cc: row.cc,
    subject: row.subject,
    body: row.body,
    createdAt: row.createdAt.toISOString(),
  };
}
