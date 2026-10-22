import type { Label } from '@burrow/contracts';
import type { Db } from '@burrow/platform';
import { and, eq, inArray } from 'drizzle-orm';
import { pensieveLabels, recordingLabels } from './schema';

export class LabelError extends Error {}

const same = (a: string, b: string) =>
  a.trim().toLocaleLowerCase() === b.trim().toLocaleLowerCase();

// A person's own labels. They can put them on any recording they can see;
// callers check that. Names are matched without regard to case, so "werk"
// and "Werk" are one label.
export class Labels {
  constructor(private readonly db: () => Db) {}

  private own(personId: string) {
    return this.db()
      .select()
      .from(pensieveLabels)
      .where(eq(pensieveLabels.personId, personId))
      .all();
  }

  // With how many of `visible` carry each label.
  list(personId: string, visible: string[]): Label[] {
    const counts = new Map<string, number>();
    if (visible.length) {
      for (const link of this.db()
        .select({ labelId: recordingLabels.labelId })
        .from(recordingLabels)
        .innerJoin(
          pensieveLabels,
          eq(pensieveLabels.id, recordingLabels.labelId),
        )
        .where(
          and(
            eq(pensieveLabels.personId, personId),
            inArray(recordingLabels.recordingId, visible),
          ),
        )
        .all()) {
        counts.set(link.labelId, (counts.get(link.labelId) ?? 0) + 1);
      }
    }
    return this.own(personId)
      .map((l) => ({ id: l.id, name: l.name, count: counts.get(l.id) ?? 0 }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  ensure(personId: string, name: string) {
    const found = this.own(personId).find((l) => same(l.name, name));
    if (found) return found;
    return this.db()
      .insert(pensieveLabels)
      .values({ personId, name: name.trim() })
      .returning()
      .get();
  }

  // Renaming onto an existing name merges the two.
  rename(personId: string, id: string, name: string) {
    const all = this.own(personId);
    const label = all.find((l) => l.id === id);
    if (!label) throw new LabelError('not found');
    const other = all.find((l) => l.id !== id && same(l.name, name));
    if (!other) {
      return this.db()
        .update(pensieveLabels)
        .set({ name: name.trim() })
        .where(eq(pensieveLabels.id, id))
        .returning()
        .get();
    }
    const links = this.db()
      .select()
      .from(recordingLabels)
      .where(eq(recordingLabels.labelId, id))
      .all();
    for (const link of links) {
      this.db()
        .insert(recordingLabels)
        .values({ recordingId: link.recordingId, labelId: other.id })
        .onConflictDoNothing()
        .run();
    }
    this.db().delete(pensieveLabels).where(eq(pensieveLabels.id, id)).run();
    return other;
  }

  remove(personId: string, id: string) {
    const label = this.own(personId).find((l) => l.id === id);
    if (!label) throw new LabelError('not found');
    this.db().delete(pensieveLabels).where(eq(pensieveLabels.id, id)).run();
  }

  // Replaces the person's labels on one recording; new names become labels.
  set(personId: string, recordingId: string, names: string[]) {
    const wanted = names
      .filter((n) => n.trim())
      .map((n) => this.ensure(personId, n));
    const mine = this.own(personId).map((l) => l.id);
    if (mine.length) {
      this.db()
        .delete(recordingLabels)
        .where(
          and(
            eq(recordingLabels.recordingId, recordingId),
            inArray(recordingLabels.labelId, mine),
          ),
        )
        .run();
    }
    for (const label of wanted) {
      this.db()
        .insert(recordingLabels)
        .values({ recordingId, labelId: label.id })
        .onConflictDoNothing()
        .run();
    }
  }

  // The person's label names per recording.
  namesFor(personId: string, recordingIds: string[]) {
    const out = new Map<string, string[]>();
    if (!recordingIds.length) return out;
    const rows = this.db()
      .select({
        recordingId: recordingLabels.recordingId,
        name: pensieveLabels.name,
      })
      .from(recordingLabels)
      .innerJoin(pensieveLabels, eq(pensieveLabels.id, recordingLabels.labelId))
      .where(
        and(
          eq(pensieveLabels.personId, personId),
          inArray(recordingLabels.recordingId, recordingIds),
        ),
      )
      .all();
    for (const row of rows) {
      out.set(row.recordingId, [...(out.get(row.recordingId) ?? []), row.name]);
    }
    for (const names of out.values()) names.sort((a, b) => a.localeCompare(b));
    return out;
  }

  // Recordings carrying any of the names (OR), among the person's labels.
  recordingsWith(personId: string, names: string[]) {
    const ids = this.own(personId)
      .filter((l) => names.some((n) => same(l.name, n)))
      .map((l) => l.id);
    if (!ids.length) return new Set<string>();
    return new Set(
      this.db()
        .select({ id: recordingLabels.recordingId })
        .from(recordingLabels)
        .where(inArray(recordingLabels.labelId, ids))
        .all()
        .map((r) => r.id),
    );
  }

  // Recordings with a label whose name contains the words, for search.
  matching(personId: string, query: string) {
    const q = query.trim().toLocaleLowerCase();
    const names = this.own(personId)
      .map((l) => l.name)
      .filter((n) => n.toLocaleLowerCase().includes(q));
    return this.recordingsWith(personId, names);
  }
}
