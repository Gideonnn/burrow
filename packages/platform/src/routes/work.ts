import {
  claimRequest,
  routineInput,
  type RunnersResponse,
  updateRunnerRequest,
} from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import type { PlatformEnv } from '../env';
import { requireRight } from '../middleware';
import { RoutineError } from '../workers/routines';
import { WorkerError } from '../workers/tasks';

const asHttp = (error: unknown): never => {
  if (error instanceof RoutineError || error instanceof WorkerError) {
    throw new HTTPException(error.message === 'not found' ? 404 : 400, {
      message: error.message,
    });
  }
  throw error;
};

const failRequest = z.object({ error: z.string().min(1) });
const tasksQuery = z.object({
  kind: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(200).default(100),
});

// The bots, routines and tasks of the key's person. Configuring routines and
// reviewing tasks needs organize; acting as a runner needs the tasks right.
export const workRoutes = new Hono<PlatformEnv>()
  .get('/catalog', requireRight('read'), (c) => {
    const { catalog } = c.var.platform;
    return c.json({
      bots: [...catalog.bots.values()].map(
        ({ name, displayName, description, model, agent, skills }) => ({
          name,
          displayName,
          description,
          model,
          agent,
          skills,
        }),
      ),
      skills: [...catalog.skills.values()].map(({ name, description }) => ({
        name,
        description,
      })),
    });
  })
  .get('/routines', requireRight('read'), (c) =>
    c.json(c.var.platform.routines.list(c.var.access.personId)),
  )
  .post(
    '/routines',
    requireRight('organize'),
    zValidator('json', routineInput),
    (c) => {
      try {
        return c.json(
          c.var.platform.routines.create(
            c.var.access.personId,
            c.req.valid('json'),
          ),
          201,
        );
      } catch (error) {
        return asHttp(error);
      }
    },
  )
  .put(
    '/routines/:id',
    requireRight('organize'),
    zValidator('json', routineInput),
    (c) => {
      try {
        return c.json(
          c.var.platform.routines.update(
            c.var.access.personId,
            c.req.param('id'),
            c.req.valid('json'),
          ),
        );
      } catch (error) {
        return asHttp(error);
      }
    },
  )
  .delete('/routines/:id', requireRight('organize'), (c) => {
    if (
      !c.var.platform.routines.remove(c.var.access.personId, c.req.param('id'))
    ) {
      throw new HTTPException(404, { message: 'not found' });
    }
    return c.json({ deleted: true });
  })
  .get('/tasks', requireRight('read'), zValidator('query', tasksQuery), (c) => {
    const { kind, limit } = c.req.valid('query');
    return c.json(
      c.var.platform.workers.list(c.var.access, {
        limit,
        kinds: kind ? [kind] : undefined,
      }),
    );
  })
  .post('/tasks/:id/approve', requireRight('organize'), async (c) => {
    try {
      await c.var.platform.workers.approve(c.req.param('id'), c.var.access);
    } catch (error) {
      asHttp(error);
    }
    return c.json({ approved: true });
  })
  .post('/tasks/:id/reject', requireRight('organize'), (c) => {
    try {
      c.var.platform.workers.reject(c.req.param('id'), c.var.access);
    } catch (error) {
      asHttp(error);
    }
    return c.json({ rejected: true });
  })
  .post('/tasks/:id/retry', requireRight('organize'), (c) => {
    try {
      c.var.platform.workers.retry(c.req.param('id'), c.var.access);
    } catch (error) {
      asHttp(error);
    }
    return c.json({ queued: true });
  })
  .post(
    '/runner/claim',
    requireRight('tasks'),
    zValidator('json', claimRequest),
    (c) => {
      if (c.var.access.factsOnly) {
        throw new HTTPException(403, { message: 'this key reads facts only' });
      }
      return c.json(
        c.var.platform.workers.claim(c.var.access, c.req.valid('json')),
      );
    },
  )
  // Every runner of the household, and the work waiting for the key's person.
  .get('/runners', requireRight('read'), (c) =>
    c.json<RunnersResponse>({
      runners: c.var.platform.workers.runners(c.var.access),
      work: c.var.platform.workers.work(c.var.access),
    }),
  )
  .patch(
    '/runners/:id',
    requireRight('tasks'),
    zValidator('json', updateRunnerRequest),
    (c) => {
      try {
        return c.json(
          c.var.platform.workers.setPaused(
            c.req.param('id'),
            c.var.access,
            c.req.valid('json').paused,
          ),
        );
      } catch (error) {
        return asHttp(error);
      }
    },
  )
  .delete('/runners/:id', requireRight('tasks'), (c) => {
    try {
      c.var.platform.workers.removeRunner(c.req.param('id'), c.var.access);
    } catch (error) {
      asHttp(error);
    }
    return c.json({ deleted: true });
  })
  .post('/runner/tasks/:id/complete', requireRight('tasks'), async (c) => {
    try {
      await c.var.platform.workers.complete(
        c.req.param('id'),
        c.var.access,
        await c.req.json(),
      );
    } catch (error) {
      asHttp(error);
    }
    return c.json({ accepted: true });
  })
  .post(
    '/runner/tasks/:id/fail',
    requireRight('tasks'),
    zValidator('json', failRequest),
    (c) => {
      try {
        c.var.platform.workers.fail(
          c.req.param('id'),
          c.var.access,
          c.req.valid('json').error,
        );
      } catch (error) {
        asHttp(error);
      }
      return c.json({ failed: true });
    },
  );
