import type { MailService } from './service';

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
