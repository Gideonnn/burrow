import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { canSeeMailbox } from '../auth/access';
import { requireRight } from '../auth/middleware';
import type { AppEnv } from '../env';
import type { InsightsService } from '../triage/insights';

export function insightsRoutes(insights: InsightsService) {
  return new Hono<AppEnv>().get(
    '/messages/:id/insights',
    requireRight('read'),
    async (c) => {
      const row = c.var.mail.message(c.req.param('id'));
      if (!row || !canSeeMailbox(c.var.access, row.mailboxId)) {
        throw new HTTPException(404, { message: 'not found' });
      }
      try {
        return c.json(await insights.get(row.id));
      } catch (error) {
        throw new HTTPException(502, {
          message: `the bot could not answer: ${(error as Error).message}`,
        });
      }
    },
  );
}
