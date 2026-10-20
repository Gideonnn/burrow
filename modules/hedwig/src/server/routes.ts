import {
  aiSearchRequest,
  createDraftRequest,
  mailFolder,
  mailboxOrderRequest,
  type MailboxSummary,
  messageActionsRequest,
  type SearchResponse,
  sendRequest,
  updateMailboxRequest,
} from '@burrow/contracts';
import { notFound, type PlatformEnv, requireRight } from '@burrow/platform';
import { zValidator } from '@hono/zod-validator';
import { and, desc, eq, lt } from 'drizzle-orm';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { canSeeMailbox } from './access';
import { createDraft, deleteDraft, DraftError, listDrafts } from './drafts';
import type { InsightsService } from './insights';
import {
  MailError,
  type MailService,
  toDetail,
  toSummary,
} from './mail-service';
import { mailboxes, messages } from './schema';
import { type SearchService, searchMessages, words } from './search';
import type { TriageService } from './triage';

const listQuery = z.object({
  folder: mailFolder.default('inbox'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.iso.datetime().optional(),
});
const searchQuery = z.object({
  q: z.string().trim().min(1).max(500),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});
const confirmRequest = z.object({ ids: z.array(z.string()).min(1) });

export const mailboxColumns = {
  id: mailboxes.id,
  ownerId: mailboxes.ownerId,
  provider: mailboxes.provider,
  address: mailboxes.address,
  name: mailboxes.name,
  role: mailboxes.role,
  instructions: mailboxes.instructions,
};

export type HedwigRouteDeps = {
  mail: MailService;
  triage: TriageService;
  insights: InsightsService;
  search: SearchService;
  // Called with the ids of messages that just arrived in an inbox.
  onArrived: (messageIds: string[]) => void;
};

// Mail, drafts, the "Gefilterd" review and the bot's suggestions. Mailboxes
// and messages outside the key's scope answer 404, so a key cannot even
// learn that they exist.
export function hedwigRoutes({
  mail,
  triage,
  insights,
  search,
  onArrived,
}: HedwigRouteDeps) {
  return (
    new Hono<PlatformEnv>()
      // The person orders their mailboxes in the sidebar.
      .put(
        '/mailboxes/order',
        requireRight('organize'),
        zValidator('json', mailboxOrderRequest),
        (c) => {
          const { ids } = c.req.valid('json');
          if (!ids.every((id) => canSeeMailbox(c.var.access, id)))
            throw notFound();
          c.var.db.transaction((tx) => {
            ids.forEach((id, position) =>
              tx
                .update(mailboxes)
                .set({ position })
                .where(eq(mailboxes.id, id))
                .run(),
            );
          });
          return c.body(null, 204);
        },
      )
      // The person renames a mailbox, says what it is for, or gives the bots
      // instructions for it.
      .patch(
        '/mailboxes/:id',
        requireRight('organize'),
        zValidator('json', updateMailboxRequest),
        (c) => {
          const id = c.req.param('id');
          if (!canSeeMailbox(c.var.access, id)) throw notFound();
          const row = c.var.db
            .update(mailboxes)
            .set(c.req.valid('json'))
            .where(eq(mailboxes.id, id))
            .returning(mailboxColumns)
            .get();
          return c.json<MailboxSummary>(row!);
        },
      )
      // Admins see which mailboxes exist and who owns them, never their mail.
      .get('/admin/mailboxes', requireRight('admin'), (c) =>
        c.json(c.var.db.select(mailboxColumns).from(mailboxes).all()),
      )
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
      // Word search over every mailbox the key sees, as you type.
      .get(
        '/search',
        requireRight('read'),
        zValidator('query', searchQuery),
        (c) => {
          const { q, limit } = c.req.valid('query');
          return c.json<SearchResponse>({
            explanation: null,
            results: searchMessages(c.var.db, c.var.access.mailboxIds, {
              groups: words(q),
              matchAll: true,
              limit,
            }),
          });
        },
      )
      // Search by meaning: the bot reads the question, never the mail.
      .post(
        '/search/ai',
        requireRight('read'),
        zValidator('json', aiSearchRequest),
        async (c) => {
          if (!search.available) {
            throw new HTTPException(503, {
              message: 'zoeken met AI is niet beschikbaar op deze server',
            });
          }
          const { question } = c.req.valid('json');
          return c.json<SearchResponse>(
            await search.ask(
              c.var.access.personId,
              c.var.access.mailboxIds,
              question,
            ),
          );
        },
      )
      .post('/mailboxes/:mailboxId/sync', requireRight('read'), async (c) => {
        const mailboxId = c.req.param('mailboxId');
        if (!canSeeMailbox(c.var.access, mailboxId)) throw notFound();
        const arrived = await mail.sync(mailboxId);
        onArrived(arrived);
        return c.json({ arrived: arrived.length });
      })
      .get('/messages/:id', requireRight('read'), (c) => {
        const row = mail.message(c.req.param('id'));
        if (!row || !canSeeMailbox(c.var.access, row.mailboxId)) {
          throw notFound();
        }
        return c.json(toDetail(row));
      })
      .post(
        '/messages/:id/actions',
        requireRight('organize'),
        zValidator('json', messageActionsRequest),
        async (c) => {
          const row = mail.message(c.req.param('id'));
          if (!row || !canSeeMailbox(c.var.access, row.mailboxId)) {
            throw notFound();
          }
          const updated = await providerCall(() =>
            mail.apply(row.id, c.req.valid('json').ops),
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
          if (!canSeeMailbox(c.var.access, request.mailboxId)) {
            throw notFound();
          }
          try {
            await providerCall(() => mail.send(request));
          } catch (error) {
            if (error instanceof MailError) {
              throw new HTTPException(400, { message: error.message });
            }
            throw error;
          }
          return c.json({ sent: true }, 202);
        },
      )
      .get('/messages/:id/insights', requireRight('read'), async (c) => {
        const row = mail.message(c.req.param('id'));
        if (!row || !canSeeMailbox(c.var.access, row.mailboxId)) {
          throw notFound();
        }
        const owner = mail.mailbox(row.mailboxId)!.ownerId;
        if (!c.var.platform.settings.enabled(owner, 'hedwig.insights')) {
          return c.json({ summary: null, replies: [] });
        }
        try {
          return c.json(await insights.get(row.id));
        } catch (error) {
          throw new HTTPException(502, {
            message: `the bot could not answer: ${(error as Error).message}`,
          });
        }
      })
      .get('/drafts', requireRight('read'), (c) =>
        c.json(listDrafts(c.var.db, c.var.access)),
      )
      .post(
        '/drafts',
        requireRight('draft'),
        zValidator('json', createDraftRequest),
        (c) => {
          try {
            return c.json(
              createDraft(c.var.db, c.var.access, c.req.valid('json')),
              201,
            );
          } catch (error) {
            if (error instanceof DraftError) {
              throw new HTTPException(
                error.message === 'not found' ? 404 : 400,
                { message: error.message },
              );
            }
            throw error;
          }
        },
      )
      // Discarding is part of handling a draft, so read is enough; it never
      // touches the provider.
      .delete('/drafts/:id', requireRight('read'), (c) => {
        if (!deleteDraft(c.var.db, c.var.access, c.req.param('id'))) {
          throw notFound();
        }
        return c.json({ deleted: true });
      })
      // The "Gefilterd" review and the rules learned from corrections.
      .get('/filtered', requireRight('read'), (c) =>
        c.json(triage.listFiltered(c.var.access)),
      )
      .post(
        '/filtered/confirm',
        requireRight('organize'),
        zValidator('json', confirmRequest),
        (c) =>
          c.json({
            confirmed: triage.confirm(c.req.valid('json').ids, c.var.access),
          }),
      )
      .post('/filtered/confirm-all', requireRight('organize'), (c) =>
        c.json({ confirmed: triage.confirmAll(c.var.access) }),
      )
      .post('/filtered/:id/restore', requireRight('organize'), async (c) => {
        try {
          await triage.restore(c.req.param('id'), c.var.access);
        } catch (error) {
          if ((error as Error).message === 'not found') throw notFound();
          throw error;
        }
        return c.json({ restored: true });
      })
      .get('/rules', requireRight('read'), (c) =>
        c.json(
          triage.rules(c.var.access.personId).map((r) => ({
            id: r.id,
            text: r.text,
            createdAt: r.createdAt.toISOString(),
          })),
        ),
      )
      .delete('/rules/:id', requireRight('organize'), (c) => {
        if (!triage.deleteRule(c.var.access.personId, c.req.param('id'))) {
          throw notFound();
        }
        return c.json({ deleted: true });
      })
  );
}

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
