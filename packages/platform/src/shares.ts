import { and, eq } from 'drizzle-orm';
import type { Db } from './db';
import { shares } from './schema';

// An owner shares one item of a module with another person of the household.
export class Shares {
  constructor(private readonly db: Db) {}

  share(module: string, itemId: string, personId: string) {
    this.db
      .insert(shares)
      .values({ module, itemId, personId })
      .onConflictDoNothing()
      .run();
  }

  unshare(module: string, itemId: string, personId: string) {
    this.db
      .delete(shares)
      .where(
        and(
          eq(shares.module, module),
          eq(shares.itemId, itemId),
          eq(shares.personId, personId),
        ),
      )
      .run();
  }

  // Item ids of a module shared with the person.
  sharedWith(module: string, personId: string): string[] {
    return this.db
      .select({ itemId: shares.itemId })
      .from(shares)
      .where(and(eq(shares.module, module), eq(shares.personId, personId)))
      .all()
      .map((r) => r.itemId);
  }

  // People an item is shared with.
  of(module: string, itemId: string): string[] {
    return this.db
      .select({ personId: shares.personId })
      .from(shares)
      .where(and(eq(shares.module, module), eq(shares.itemId, itemId)))
      .all()
      .map((r) => r.personId);
  }

  removeItem(module: string, itemId: string) {
    this.db
      .delete(shares)
      .where(and(eq(shares.module, module), eq(shares.itemId, itemId)))
      .run();
  }
}
