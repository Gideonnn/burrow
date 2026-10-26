import type { RequestState } from '@burrow/contracts';
import type { Platform } from '@burrow/platform';
import { and, eq, isNull, lte } from 'drizzle-orm';
import { type MediaRequester, refKey, type TitleRef } from './catalogue';
import { lumosListItems, lumosRequests } from './schema';
import { SeerrError } from './seerr';

// Undo within this window stops the request before it leaves.
export const REQUEST_GRACE_MS = 15_000;
const MAX_ATTEMPTS = 8;
const backoff = (attempts: number) =>
  Math.min(6 * 60 * 60_000, 60_000 * 2 ** (attempts - 1));

type Tx = Parameters<Parameters<Platform['db']['transaction']>[0]>[0];
type Row = typeof lumosRequests.$inferSelect;

export const requestState = (row: Row): RequestState => ({
  status: row.status,
  seasons: row.seasons,
  error: row.lastError,
  attempts: row.attempts,
  nextAttemptAt:
    row.status === 'pending'
      ? (row.nextAttemptAt?.toISOString() ?? null)
      : null,
  updatedAt: row.updatedAt.toISOString(),
});

// Putting a live title on a list asks the media server for it, once per
// title: the household shares one Seerr key and one library.
export class LumosRequests {
  private running?: Promise<void>;
  private again = false;

  constructor(
    private readonly platform: Platform,
    private readonly requester: MediaRequester,
  ) {}

  private get db() {
    return this.platform.db;
  }

  // In the list entry's own transaction, so a wish never lacks its request.
  want(
    tx: Tx,
    ref: TitleRef,
    seasons: number[] | null,
    by: string,
    now = new Date(),
  ) {
    const existing = tx
      .select()
      .from(lumosRequests)
      .where(
        and(
          eq(lumosRequests.mediaType, ref.mediaType),
          eq(lumosRequests.tmdbId, ref.tmdbId),
        ),
      )
      .get();
    const next = new Date(now.getTime() + REQUEST_GRACE_MS);
    if (!existing) {
      tx.insert(lumosRequests)
        .values({
          mediaType: ref.mediaType,
          tmdbId: ref.tmdbId,
          seasons,
          status: 'pending',
          nextAttemptAt: next,
          requestedBy: by,
          updatedAt: now,
        })
        .run();
    } else if (existing.status === 'dropped' || existing.status === 'failed') {
      tx.update(lumosRequests)
        .set({
          status: 'pending',
          seasons,
          attempts: 0,
          lastError: null,
          nextAttemptAt: next,
          requestedBy: by,
          updatedAt: now,
        })
        .where(eq(lumosRequests.id, existing.id))
        .run();
    }
  }

  all() {
    return new Map(
      this.db
        .select()
        .from(lumosRequests)
        .all()
        .map((r) => [refKey(r), r]),
    );
  }

  get(ref: TitleRef) {
    return this.all().get(refKey(ref));
  }

  // After the grace period, outside the request that made the wish.
  schedule() {
    setTimeout(() => void this.run(), REQUEST_GRACE_MS + 500).unref();
  }

  run(now?: Date): Promise<void> {
    if (this.running) {
      this.again = true;
      return this.running;
    }
    this.running = (async () => {
      do {
        this.again = false;
        await this.process(now);
      } while (this.again);
    })().finally(() => {
      this.running = undefined;
    });
    return this.running;
  }

  private async process(now = new Date()) {
    const due = this.db
      .select()
      .from(lumosRequests)
      .where(
        and(
          eq(lumosRequests.status, 'pending'),
          lte(lumosRequests.nextAttemptAt, now),
        ),
      )
      .all();
    for (const row of due) await this.send(row, now);
  }

  // Still on someone's list? A wish undone or removed before it left is
  // dropped; one that left is never cancelled.
  private wanted(ref: TitleRef) {
    return Boolean(
      this.db
        .select({ id: lumosListItems.id })
        .from(lumosListItems)
        .where(
          and(
            eq(lumosListItems.mediaType, ref.mediaType),
            eq(lumosListItems.tmdbId, ref.tmdbId),
            eq(lumosListItems.origin, 'live'),
            isNull(lumosListItems.removedAt),
          ),
        )
        .get(),
    );
  }

  private set(row: Row, values: Partial<Row>, now: Date) {
    this.db
      .update(lumosRequests)
      .set({ ...values, updatedAt: now })
      .where(eq(lumosRequests.id, row.id))
      .run();
  }

  private async send(row: Row, now: Date) {
    if (!this.wanted(row)) {
      this.set(row, { status: 'dropped', nextAttemptAt: null }, now);
      return this.changed();
    }
    try {
      const state = await this.requester.state(row);
      if (state.known) {
        this.set(
          row,
          {
            status: 'exists',
            seerrRequestId: state.requestId,
            lastError: null,
            nextAttemptAt: null,
          },
          now,
        );
      } else {
        const made = await this.requester.request(row, row.seasons);
        this.set(
          row,
          {
            status: made.existed ? 'exists' : 'sent',
            seerrRequestId: made.requestId,
            attempts: row.attempts + 1,
            lastError: null,
            nextAttemptAt: null,
          },
          now,
        );
      }
    } catch (error) {
      const attempts = row.attempts + 1;
      // Only messages Lumos wrote itself: an upstream body never lands here.
      const message =
        error instanceof SeerrError
          ? error.message
          : 'Onverwachte fout bij Seerr';
      this.set(
        row,
        {
          attempts,
          lastError: message,
          status: attempts >= MAX_ATTEMPTS ? 'failed' : 'pending',
          nextAttemptAt: new Date(now.getTime() + backoff(attempts)),
        },
        now,
      );
    }
    this.changed();
  }

  // "Opnieuw proberen" after the retries gave up.
  retry(ref: TitleRef, now = new Date()) {
    const row = this.get(ref);
    if (!row || row.status !== 'failed') return false;
    this.set(
      row,
      { status: 'pending', attempts: 0, lastError: null, nextAttemptAt: now },
      now,
    );
    void this.run();
    return true;
  }

  private changed() {
    this.platform.events.emit({
      data: { type: 'lumos.changed', scope: 'shared' },
      visibleTo: () => true,
    });
  }

  start() {
    void this.run();
    const timer = setInterval(() => void this.run(), 60_000);
    timer.unref();
    return () => clearInterval(timer);
  }
}
