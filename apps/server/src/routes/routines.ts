import { routineInput } from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { requireRight } from '../auth/middleware';
import type { AppEnv } from '../env';
import { RoutineError, type RoutineService } from '../routines/service';

const asHttp = (error: unknown): never => {
  if (error instanceof RoutineError) {
    throw new HTTPException(error.message === 'not found' ? 404 : 400, {
      message: error.message,
    });
  }
  throw error;
};

const claimRequest = z.object({
  runner: z.string().min(1).max(80),
  max: z.number().int().min(1).max(5).default(2),
});
const failRequest = z.object({ error: z.string().min(1) });

// Routines and tasks are per person. Configuring routines and reviewing tasks
// needs organize; acting as a runner needs the tasks right.
export function routineRoutes(routines: RoutineService) {
  return new Hono<AppEnv>()
    .get('/routines', requireRight('read'), (c) =>
      c.json(routines.list(c.var.access.personId)),
    )
    .post(
      '/routines',
      requireRight('organize'),
      zValidator('json', routineInput),
      (c) => {
        try {
          return c.json(
            routines.create(c.var.access.personId, c.req.valid('json')),
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
            routines.update(
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
      if (!routines.remove(c.var.access.personId, c.req.param('id'))) {
        throw new HTTPException(404, { message: 'not found' });
      }
      return c.json({ deleted: true });
    })
    .get('/tasks', requireRight('read'), (c) =>
      c.json(routines.listTasks(c.var.access)),
    )
    .post('/tasks/:id/approve', requireRight('organize'), async (c) => {
      try {
        await routines.approve(c.req.param('id'), c.var.access);
      } catch (error) {
        asHttp(error);
      }
      return c.json({ approved: true });
    })
    .post('/tasks/:id/reject', requireRight('organize'), (c) => {
      try {
        routines.reject(c.req.param('id'), c.var.access);
      } catch (error) {
        asHttp(error);
      }
      return c.json({ rejected: true });
    })
    .post(
      '/runner/claim',
      requireRight('tasks'),
      zValidator('json', claimRequest),
      (c) => {
        const { runner, max } = c.req.valid('json');
        return c.json(routines.claim(c.var.access, runner, max));
      },
    )
    .post('/runner/tasks/:id/complete', requireRight('tasks'), async (c) => {
      try {
        routines.complete(c.req.param('id'), c.var.access, await c.req.json());
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
          routines.fail(
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
}
