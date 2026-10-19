import {
  mailFolder,
  messageActionsRequest,
  sendRequest,
} from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { and, desc, eq, lt } from 'drizzle-orm';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { streamSSE } from 'hono/streaming';
import { z } from 'zod';
import { canSeeMailbox } from '../auth/access';
import { requireRight } from '../auth/middleware';
import { messages } from '../db/schema';
import type { AppEnv } from '../env';
import { MailError, toDetail, toSummary } from '../mail/service';

const listQuery = z.object({
  folder: mailFolder.default('inbox'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.iso.datetime().optional(),
});

// Mailboxes and messages outside the key's scope answer 404, not 403, so a
// key cannot even learn that they exist.
const notFound = () => new HTTPException(404, { message: 'not found' });

export const mailRoutes = new Hono<AppEnv>()
  .get(
    '/mailboxes/:mailboxId/messages',
    requireRight('read'),
    zValidator('query', listQuery),
    (c) => {
      const mailboxId = c.req.param('mailboxId');
      if (!canSeeMailbox(c.var.access, mailboxId)) throw notFound();
      const { folder, limit, before } = c.req.valid('query');
      const rows = c.var.db
        .select()
        .from(messages)
        .where(
          and(
            eq(messages.mailboxId, mailboxId),
            eq(messages.folder, folder),
            before ? lt(messages.receivedAt, new Date(before)) : undefined,
          ),
        )
        .orderBy(desc(messages.receivedAt))
        .limit(limit)
        .all();
      return c.json(rows.map(toSummary));
    },
  )
  .post('/mailboxes/:mailboxId/sync', requireRight('read'), async (c) => {
    const mailboxId = c.req.param('mailboxId');
    if (!canSeeMailbox(c.var.access, mailboxId)) throw notFound();
    const arrived = await c.var.mail.sync(mailboxId);
    c.var.onArrived(arrived);
    return c.json({ arrived: arrived.length });
  })
  .get('/messages/:id', requireRight('read'), (c) => {
    const row = c.var.mail.message(c.req.param('id'));
    if (!row || !canSeeMailbox(c.var.access, row.mailboxId)) throw notFound();
    return c.json(toDetail(row));
  })
  .post(
    '/messages/:id/actions',
    requireRight('organize'),
    zValidator('json', messageActionsRequest),
    async (c) => {
      const row = c.var.mail.message(c.req.param('id'));
      if (!row || !canSeeMailbox(c.var.access, row.mailboxId)) throw notFound();
      const updated = await providerCall(() =>
        c.var.mail.apply(row.id, c.req.valid('json').ops),
      );
      return c.json(toDetail(updated));
    },
  )
  .post(
    '/send',
    requireRight('send'),
    zValidator('json', sendRequest),
    async (c) => {
      const request = c.req.valid('json');
      if (!canSeeMailbox(c.var.access, request.mailboxId)) throw notFound();
      try {
        await providerCall(() => c.var.mail.send(request));
      } catch (error) {
        if (error instanceof MailError) {
          throw new HTTPException(400, { message: error.message });
        }
        throw error;
      }
      return c.json({ sent: true }, 202);
    },
  )
  .get('/events', requireRight('read'), (c) => {
    const { access, events } = c.var;
    return streamSSE(c, async (stream) => {
      const unsubscribe = events.subscribe((event) => {
        if (!canSeeMailbox(access, event.mailboxId)) return;
        void stream.writeSSE({
          event: event.type,
          data: JSON.stringify(event),
        });
      });
      stream.onAbort(unsubscribe);
      while (!stream.aborted) {
        await stream.writeSSE({ event: 'ping', data: '{}' });
        await stream.sleep(25_000);
      }
      unsubscribe();
    });
  });

// A provider failure is a bad gateway, not our own internal error: the client
// can show "Gmail refused" and retry.
async function providerCall<T>(call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    if (error instanceof MailError || error instanceof HTTPException)
      throw error;
    throw new HTTPException(502, {
      message: `the mail provider refused: ${(error as Error).message}`,
    });
  }
}
