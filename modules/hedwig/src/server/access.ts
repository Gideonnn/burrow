import type {
  Access,
  AccessExtender,
  Db,
  RestrictionCheck,
  Shares,
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

// Whether a key may be given messages shared with its person: not a
// facts-only key, and not one narrowed to some mailboxes.
export const readsShared = (access: Access) =>
  !access.factsOnly && !access.restrictions.mailboxes;

// The owner's keys, and the reading keys of everyone it is shared with.
// Organizing stays with the owner: those routes check canSeeMailbox.
export const canSeeMessage = (
  access: Access,
  row: { id: string; mailboxId: string },
  shares: Shares,
) =>
  canSeeMailbox(access, row.mailboxId) ||
  (readsShared(access) &&
    access.rights.has('read') &&
    shares.of('hedwig', row.id).includes(access.personId));
