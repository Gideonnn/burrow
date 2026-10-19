import { createDraftRequest } from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { requireRight } from '../auth/middleware';
import type { AppEnv } from '../env';
import {
  createDraft,
  deleteDraft,
  DraftError,
  listDrafts,
} from '../mail/drafts';

export const draftRoutes = new Hono<AppEnv>()
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
          throw new HTTPException(error.message === 'not found' ? 404 : 400, {
            message: error.message,
          });
        }
        throw error;
      }
    },
  )
  // Discarding is part of handling a draft, so read is enough; it never
  // touches the provider.
  .delete('/drafts/:id', requireRight('read'), (c) => {
    if (!deleteDraft(c.var.db, c.var.access, c.req.param('id'))) {
      throw new HTTPException(404, { message: 'not found' });
    }
    return c.json({ deleted: true });
  });
