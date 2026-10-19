import type { ApiKeySummary, CreateKeyRequest } from '@burrow/contracts';
import { and, eq, inArray } from 'drizzle-orm';
import { generateToken } from '../auth/keys';
import type { Db } from '../db/client';
import { apiKeys, mailboxes, people } from '../db/schema';

export class AccessError extends Error {}

export function createPerson(db: Db, name: string) {
  return db.insert(people).values({ name }).returning().get();
}

export function listPeople(db: Db) {
  return db.select().from(people).orderBy(people.createdAt).all();
}

export function createKey(db: Db, request: CreateKeyRequest) {
  const person = db
    .select()
    .from(people)
    .where(eq(people.id, request.personId))
    .get();
  if (!person) throw new AccessError('unknown person');

  if (request.mailboxIds?.length) {
    const owned = db
      .select({ id: mailboxes.id })
      .from(mailboxes)
      .where(
        and(
          eq(mailboxes.ownerId, person.id),
          inArray(mailboxes.id, request.mailboxIds),
        ),
      )
      .all();
    if (owned.length !== new Set(request.mailboxIds).size) {
      throw new AccessError(
        'a key can only include its own person’s mailboxes',
      );
    }
  }

  const { token, hash, prefix } = generateToken();
  const row = db
    .insert(apiKeys)
    .values({
      personId: person.id,
      name: request.name,
      hash,
      prefix,
      rights: [...new Set(request.rights)],
      mailboxIds: request.mailboxIds,
    })
    .returning()
    .get();
  return { key: summarizeKey(row), token };
}

export function listKeys(db: Db) {
  return db
    .select()
    .from(apiKeys)
    .orderBy(apiKeys.createdAt)
    .all()
    .map(summarizeKey);
}

export function revokeKey(db: Db, id: string) {
  const row = db
    .update(apiKeys)
    .set({ revokedAt: new Date() })
    .where(eq(apiKeys.id, id))
    .returning()
    .get();
  if (!row) throw new AccessError('unknown key');
  return summarizeKey(row);
}

function summarizeKey(row: typeof apiKeys.$inferSelect): ApiKeySummary {
  return {
    id: row.id,
    personId: row.personId,
    name: row.name,
    prefix: row.prefix,
    rights: row.rights,
    mailboxIds: row.mailboxIds,
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
    revokedAt: row.revokedAt?.toISOString() ?? null,
  };
}
