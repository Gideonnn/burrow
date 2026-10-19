import { Hono } from 'hono';
import { streamSSE } from 'hono/streaming';
import type { PlatformEnv } from '../env';
import { requireRight } from '../middleware';

// One live stream per client; each event is forwarded only when the module
// that emitted it says this key may see it.
export const eventRoutes = new Hono<PlatformEnv>().get(
  '/events',
  requireRight('read'),
  (c) => {
    const { access, events } = c.var;
    return streamSSE(c, async (stream) => {
      const unsubscribe = events.subscribe((event) => {
        if (!event.visibleTo(access)) return;
        void stream.writeSSE({
          event: event.data.type,
          data: JSON.stringify(event.data),
        });
      });
      stream.onAbort(unsubscribe);
      while (!stream.aborted) {
        await stream.writeSSE({ event: 'ping', data: '{}' });
        await stream.sleep(25_000);
      }
      unsubscribe();
    });
  },
);
