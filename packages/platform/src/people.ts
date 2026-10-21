import type {
  ApiKeySummary,
  CreateKeyRequest,
  KeyRestrictions,
} from '@burrow/contracts';
import { eq } from 'drizzle-orm';
import type { Db } from './db';
import { generateToken } from './keys';
import { apiKeys, people } from './schema';

export class AccessError extends Error {}

// Checks one module's restriction on a new key, e.g. that the listed
// mailboxes belong to the key's person.
export type RestrictionCheck = {
  name: string;
  owns: (db: Db, personId: string, ids: string[]) => boolean;
};

export type PersonRow = typeof people.$inferSelect;

export function createPerson(db: Db, name: string, admin = true) {
  return db.insert(people).values({ name, admin }).returning().get();
}

export function person(db: Db, id: string): PersonRow | undefined {
  return db.select().from(people).where(eq(people.id, id)).get();
}

export function personByName(db: Db, name: string): PersonRow | undefined {
  return db.select().from(people).where(eq(people.name, name)).get();
}

export function personByEmail(db: Db, email: string): PersonRow | undefined {
  return db
    .select()
    .from(people)
    .where(eq(people.email, email.trim().toLowerCase()))
    .get();
}

// Only the operator (the CLI on Dobby) sets login addresses: whoever controls
// a person's address can log in as them and read their mail.
export function setPersonEmail(db: Db, personId: string, email: string) {
  const row = db
    .update(people)
    .set({ email: email.trim().toLowerCase() })
    .where(eq(people.id, personId))
    .returning()
    .get();
  if (!row) throw new AccessError('unknown person');
  return row;
}

export function listPeople(db: Db) {
  return db.select().from(people).orderBy(people.createdAt).all();
}

export function createKey(
  db: Db,
  request: Omit<CreateKeyRequest, 'factsOnly'> & { factsOnly?: boolean },
  checks: readonly RestrictionCheck[] = [],
) {
  const owner = person(db, request.personId);
  if (!owner) throw new AccessError('unknown person');
  if (request.rights.includes('admin') && !owner.admin) {
    throw new AccessError('only a household admin can hold the admin right');
  }

  const restrictions: KeyRestrictions = { ...request.restrictions };
  if (request.mailboxIds) restrictions.mailboxes = request.mailboxIds;
  for (const [name, ids] of Object.entries(restrictions)) {
    const check = checks.find((c) => c.name === name);
    if (!check) throw new AccessError(`unknown restriction "${name}"`);
    if (ids.length && !check.owns(db, owner.id, [...new Set(ids)])) {
      throw new AccessError(`a key can only include its own person’s ${name}`);
    }
  }

  const { token, hash, prefix } = generateToken();
  const row = db
    .insert(apiKeys)
    .values({
      personId: owner.id,
      name: request.name,
      hash,
      prefix,
      rights: [...new Set(request.rights)],
      restrictions,
      factsOnly: request.factsOnly ?? false,
    })
    .returning()
    .get();
  return { key: summarizeKey(row), token };
}

export function listKeys(db: Db, personId?: string) {
  return db
    .select()
    .from(apiKeys)
    .where(personId ? eq(apiKeys.personId, personId) : undefined)
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

export function summarizeKey(row: typeof apiKeys.$inferSelect): ApiKeySummary {
  return {
    id: row.id,
    personId: row.personId,
    name: row.name,
    prefix: row.prefix,
    rights: row.rights,
    restrictions: row.restrictions,
    factsOnly: row.factsOnly,
    mailboxIds: row.restrictions.mailboxes ?? null,
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
    revokedAt: row.revokedAt?.toISOString() ?? null,
  };
}
