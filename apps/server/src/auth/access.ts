import type { Right } from '@burrow/contracts';
import { and, eq, inArray, isNull } from 'drizzle-orm';
import type { Db } from '../db/client';
import { apiKeys, mailboxes } from '../db/schema';
import { hashToken } from './keys';

export type Access = {
  keyId: string;
  keyName: string;
  personId: string;
  rights: ReadonlySet<Right>;
  mailboxIds: readonly string[];
};

// Resolves a bearer token to what it may do. The mailbox list is computed
// here, once per request, so every route filters on the same answer.
export function resolveAccess(db: Db, token: string): Access | undefined {
  const key = db
    .select()
    .from(apiKeys)
    .where(and(eq(apiKeys.hash, hashToken(token)), isNull(apiKeys.revokedAt)))
    .get();
  if (!key) return undefined;

  // A key is never wider than its person: a listed mailbox that was moved to
  // someone else drops out here.
  const ownedByPerson = eq(mailboxes.ownerId, key.personId);
  const owned =
    key.mailboxIds?.length === 0
      ? []
      : db
          .select({ id: mailboxes.id })
          .from(mailboxes)
          .where(
            key.mailboxIds === null
              ? ownedByPerson
              : and(ownedByPerson, inArray(mailboxes.id, key.mailboxIds)),
          )
          .all();

  db.update(apiKeys)
    .set({ lastUsedAt: new Date() })
    .where(eq(apiKeys.id, key.id))
    .run();

  return {
    keyId: key.id,
    keyName: key.name,
    personId: key.personId,
    rights: new Set(key.rights),
    mailboxIds: owned.map((m) => m.id),
  };
}

export const canSeeMailbox = (access: Access, mailboxId: string) =>
  access.mailboxIds.includes(mailboxId);
