import type { MailService } from './mail-service';

// Polls every mailbox in turn. Providers with push (JMAP) still go through
// here as a safety net; a failing mailbox is logged and retried next round
// without stopping the others.
export function startSyncLoop(
  mail: MailService,
  onArrived: (messageIds: string[]) => void,
  intervalMs = 60_000,
): () => void {
  let stopped = false;
  let timer: NodeJS.Timeout | undefined;

  const round = async () => {
    for (const box of mail.allMailboxes()) {
      if (stopped) return;
      try {
        const arrived = await mail.sync(box.id);
        if (arrived.length) onArrived(arrived);
      } catch (error) {
        console.error(
          `sync ${box.address} failed: ${(error as Error).message}`,
        );
      }
    }
    if (!stopped) timer = setTimeout(round, intervalMs);
  };
  void round();

  return () => {
    stopped = true;
    clearTimeout(timer);
  };
}

// Brings in each mailbox's older mail, a page at a time with a pause, until
// every archive is in. A failing mailbox waits a while; the others go on.
// Mailboxes connected later are picked up on the next idle round.
export function startBackfillLoop(
  mail: Pick<MailService, 'allMailboxes' | 'backfill'>,
  { pauseMs = 2_000, idleMs = 10 * 60_000 } = {},
): () => void {
  let stopped = false;
  let timer: NodeJS.Timeout | undefined;
  const failedAt = new Map<string, number>();

  const round = async () => {
    let more = false;
    for (const box of mail.allMailboxes()) {
      if (stopped) return;
      if (box.backfilledAt) continue;
      if (Date.now() - (failedAt.get(box.id) ?? -Infinity) < idleMs) continue;
      try {
        if (await mail.backfill(box.id)) more = true;
        failedAt.delete(box.id);
      } catch (error) {
        failedAt.set(box.id, Date.now());
        console.error(
          `backfill ${box.address} failed: ${(error as Error).message}`,
        );
      }
    }
    if (!stopped) timer = setTimeout(round, more ? pauseMs : idleMs);
  };
  void round();

  return () => {
    stopped = true;
    clearTimeout(timer);
  };
}
