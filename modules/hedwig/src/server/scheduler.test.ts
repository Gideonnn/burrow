import { afterEach, describe, expect, it, vi } from 'vitest';
import type { MailboxRow } from './mail-service';
import { startBackfillLoop } from './scheduler';

// Mailboxes with a number of pages left; a page of 'broken' always fails.
function fakeMail(pages: Record<string, number>) {
  const done = new Set<string>();
  const calls: string[] = [];
  return {
    calls,
    allMailboxes: () =>
      Object.keys(pages).map(
        (id) =>
          ({
            id,
            address: `${id}@example.com`,
            backfilledAt: done.has(id) ? new Date() : null,
          }) as MailboxRow,
      ),
    backfill: async (id: string) => {
      calls.push(id);
      if (id === 'broken') throw new Error('provider down');
      pages[id]!--;
      if (pages[id] === 0) done.add(id);
      return pages[id]! > 0;
    },
  };
}

afterEach(() => vi.useRealTimers());

describe('the backfill loop', () => {
  it('pages through every mailbox until the archives are in, past a failing one', async () => {
    vi.useFakeTimers();
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const mail = fakeMail({ home: 3, work: 1, broken: 1 });
    const stop = startBackfillLoop(mail, { pauseMs: 10, idleMs: 1_000 });
    await vi.advanceTimersByTimeAsync(100);
    stop();
    expect(mail.calls).toEqual(['home', 'work', 'broken', 'home', 'home']);
  });
});
