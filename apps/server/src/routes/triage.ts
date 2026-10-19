import { instructions } from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { requireRight } from '../auth/middleware';
import type { AppEnv } from '../env';
import type { TriageService } from '../triage/service';

const confirmRequest = z.object({ ids: z.array(z.string()).min(1) });

// The "Gefilterd" review, a person's standing instructions for their bots and
// the rules learned from corrections. Everything is per person: a key only
// sees its own person's instructions and its own mailboxes' filtered mail.
export function triageRoutes(triage: TriageService) {
  return new Hono<AppEnv>()
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
        if ((error as Error).message === 'not found') {
          throw new HTTPException(404, { message: 'not found' });
        }
        throw error;
      }
      return c.json({ restored: true });
    })
    .get('/instructions', requireRight('read'), (c) =>
      c.json({ text: triage.instructions(c.var.access.personId) }),
    )
    .put(
      '/instructions',
      requireRight('organize'),
      zValidator('json', instructions),
      (c) => {
        triage.setInstructions(c.var.access.personId, c.req.valid('json').text);
        return c.json({ text: c.req.valid('json').text });
      },
    )
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
        throw new HTTPException(404, { message: 'not found' });
      }
      return c.json({ deleted: true });
    });
}
