import {
  type DataOrigin,
  type ListScope,
  passKinds,
  tasteKinds,
  type VerdictKind,
} from '@burrow/contracts';
import type { Platform } from '@burrow/platform';
import { and, eq, inArray, isNull } from 'drizzle-orm';
import type { TitleRef } from './catalogue';
import {
  type ChangeEffects,
  lumosChanges,
  lumosListItems,
  lumosVerdicts,
} from './schema';

// Every list or verdict change goes through here and records what it added,
// removed and undid, so its author can undo exactly that. Nothing is
// deleted: removing and undoing set a date, undo sets it back.

export type Tx = Parameters<Parameters<Platform['db']['transaction']>[0]>[0];

// The household's rows have no owner.
export const isOwner = (
  column: typeof lumosListItems.ownerId | typeof lumosVerdicts.personId,
  owner: string | null,
) => (owner === null ? isNull(column) : eq(column, owner));

export const scopeOf = (owner: string | null): ListScope =>
  owner === null ? 'shared' : 'mine';

export const isPass = (kind: VerdictKind) =>
  (passKinds as readonly string[]).includes(kind);

// A new verdict replaces the earlier one of its group.
export const groupOf = (kind: VerdictKind) =>
  isPass(kind) ? passKinds : tasteKinds;

export const noEffects = (): ChangeEffects => ({
  listAdded: [],
  listRemoved: [],
  verdictsAdded: [],
  verdictsUndone: [],
});

export function recordChange(tx: Tx, personId: string, effects: ChangeEffects) {
  return tx
    .insert(lumosChanges)
    .values({ personId, effects })
    .returning({ id: lumosChanges.id })
    .get().id;
}

export function undoVerdicts(
  tx: Tx,
  origin: DataOrigin,
  person: string | null,
  ref: TitleRef,
  kinds: readonly VerdictKind[],
  effects: ChangeEffects,
) {
  const rows = tx
    .update(lumosVerdicts)
    .set({ undoneAt: new Date() })
    .where(
      and(
        isOwner(lumosVerdicts.personId, person),
        eq(lumosVerdicts.mediaType, ref.mediaType),
        eq(lumosVerdicts.tmdbId, ref.tmdbId),
        eq(lumosVerdicts.origin, origin),
        inArray(lumosVerdicts.kind, [...kinds]),
        isNull(lumosVerdicts.undoneAt),
      ),
    )
    .returning({ id: lumosVerdicts.id })
    .all();
  effects.verdictsUndone.push(...rows.map((r) => r.id));
}

export function insertVerdict(
  tx: Tx,
  values: typeof lumosVerdicts.$inferInsert,
  effects: ChangeEffects,
) {
  const row = tx
    .insert(lumosVerdicts)
    .values(values)
    .returning({ id: lumosVerdicts.id })
    .get();
  effects.verdictsAdded.push(row.id);
}

export function removeFromList(
  tx: Tx,
  origin: DataOrigin,
  owner: string | null,
  ref: TitleRef,
  effects: ChangeEffects,
) {
  const rows = tx
    .update(lumosListItems)
    .set({ removedAt: new Date() })
    .where(
      and(
        isOwner(lumosListItems.ownerId, owner),
        eq(lumosListItems.mediaType, ref.mediaType),
        eq(lumosListItems.tmdbId, ref.tmdbId),
        eq(lumosListItems.origin, origin),
        isNull(lumosListItems.removedAt),
      ),
    )
    .returning({ id: lumosListItems.id })
    .all();
  effects.listRemoved.push(...rows.map((r) => r.id));
}

// Reverses exactly what one change did and answers the scopes it touched. A
// row someone else has since put back (the same title re-added to the shared
// list) stays as it is.
export function undoChange(tx: Tx, changeId: string, effects: ChangeEffects) {
  const scopes = new Set<ListScope>();
  const now = new Date();
  for (const id of effects.listAdded) {
    const row = tx
      .update(lumosListItems)
      .set({ removedAt: now })
      .where(and(eq(lumosListItems.id, id), isNull(lumosListItems.removedAt)))
      .returning()
      .get();
    if (row) scopes.add(scopeOf(row.ownerId));
  }
  for (const id of effects.verdictsAdded) {
    const row = tx
      .update(lumosVerdicts)
      .set({ undoneAt: now })
      .where(and(eq(lumosVerdicts.id, id), isNull(lumosVerdicts.undoneAt)))
      .returning()
      .get();
    if (row) scopes.add(scopeOf(row.personId));
  }
  for (const id of effects.listRemoved) {
    const row = tx
      .select()
      .from(lumosListItems)
      .where(eq(lumosListItems.id, id))
      .get();
    if (!row?.removedAt) continue;
    const active = tx
      .select({ id: lumosListItems.id })
      .from(lumosListItems)
      .where(
        and(
          isOwner(lumosListItems.ownerId, row.ownerId),
          eq(lumosListItems.mediaType, row.mediaType),
          eq(lumosListItems.tmdbId, row.tmdbId),
          eq(lumosListItems.origin, row.origin),
          isNull(lumosListItems.removedAt),
        ),
      )
      .get();
    if (active) continue;
    tx.update(lumosListItems)
      .set({ removedAt: null })
      .where(eq(lumosListItems.id, id))
      .run();
    scopes.add(scopeOf(row.ownerId));
  }
  for (const id of effects.verdictsUndone) {
    const row = tx
      .select()
      .from(lumosVerdicts)
      .where(eq(lumosVerdicts.id, id))
      .get();
    if (!row?.undoneAt) continue;
    const active = tx
      .select({ id: lumosVerdicts.id })
      .from(lumosVerdicts)
      .where(
        and(
          isOwner(lumosVerdicts.personId, row.personId),
          eq(lumosVerdicts.mediaType, row.mediaType),
          eq(lumosVerdicts.tmdbId, row.tmdbId),
          eq(lumosVerdicts.origin, row.origin),
          inArray(lumosVerdicts.kind, [...groupOf(row.kind)]),
          isNull(lumosVerdicts.undoneAt),
        ),
      )
      .get();
    if (active) continue;
    tx.update(lumosVerdicts)
      .set({ undoneAt: null })
      .where(eq(lumosVerdicts.id, id))
      .run();
    scopes.add(scopeOf(row.personId));
  }
  tx.update(lumosChanges)
    .set({ undoneAt: now })
    .where(eq(lumosChanges.id, changeId))
    .run();
  return scopes;
}
