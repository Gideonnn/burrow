import type {
  Access,
  AccessExtender,
  Db,
  RestrictionCheck,
} from '@burrow/platform';
import { and, eq, inArray } from 'drizzle-orm';
import { mailboxes } from './schema';

declare module '@burrow/platform' {
  interface AccessExtensions {
    // The mailboxes this key may see: its person's, narrowed by the key's
    // `mailboxes` restriction. Every Hedwig route filters on this list.
    mailboxIds: readonly string[];
  }
}

// A key is never wider than its person: a listed mailbox that was moved to
// someone else drops out here.
export const mailboxAccess: AccessExtender = (db, key) => {
  const listed = key.restrictions.mailboxes;
  if (listed?.length === 0) return { mailboxIds: [] };
  const ownedByPerson = eq(mailboxes.ownerId, key.personId);
  const rows = db
    .select({ id: mailboxes.id })
    .from(mailboxes)
    .where(
      listed
        ? and(ownedByPerson, inArray(mailboxes.id, listed))
        : ownedByPerson,
    )
    .all();
  return { mailboxIds: rows.map((m) => m.id) };
};

export const mailboxRestriction: RestrictionCheck = {
  name: 'mailboxes',
  owns: (db: Db, personId: string, ids: string[]) =>
    db
      .select({ id: mailboxes.id })
      .from(mailboxes)
      .where(and(eq(mailboxes.ownerId, personId), inArray(mailboxes.id, ids)))
      .all().length === ids.length,
};

export const canSeeMailbox = (access: Access, mailboxId: string) =>
  access.mailboxIds.includes(mailboxId);
