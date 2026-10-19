import type { KeyRestrictions, Right } from '@burrow/contracts';
import { and, eq, isNull } from 'drizzle-orm';
import type { Db } from './db';
import { hashToken } from './keys';
import { apiKeys } from './schema';

export type KeyRow = typeof apiKeys.$inferSelect;

// Modules add what they resolve per key through declaration merging, e.g.
// Hedwig adds `mailboxIds`.
// biome-ignore lint: an empty interface is what modules merge into
export interface AccessExtensions {}

export type BaseAccess = {
  keyId: string;
  keyName: string;
  personId: string;
  rights: ReadonlySet<Right>;
  restrictions: KeyRestrictions;
};

export type Access = BaseAccess & AccessExtensions;

// Computes a module's part of the access, once per request, so every route
// filters on the same answer.
export type AccessExtender = (
  db: Db,
  key: BaseAccess,
) => Partial<AccessExtensions>;

export function resolveAccess(
  db: Db,
  token: string,
  extenders: readonly AccessExtender[] = [],
): Access | undefined {
  const key = db
    .select()
    .from(apiKeys)
    .where(and(eq(apiKeys.hash, hashToken(token)), isNull(apiKeys.revokedAt)))
    .get();
  if (!key) return undefined;
  db.update(apiKeys)
    .set({ lastUsedAt: new Date() })
    .where(eq(apiKeys.id, key.id))
    .run();
  return accessForKey(db, key, extenders);
}

export function accessForKey(
  db: Db,
  key: KeyRow,
  extenders: readonly AccessExtender[] = [],
): Access {
  const base: BaseAccess = {
    keyId: key.id,
    keyName: key.name,
    personId: key.personId,
    rights: new Set(key.rights),
    restrictions: key.restrictions,
  };
  return Object.assign(
    base,
    ...extenders.map((extend) => extend(db, base)),
  ) as Access;
}
