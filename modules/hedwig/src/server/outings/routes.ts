import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { Readable } from 'node:stream';
import {
  addTicketRequest,
  createOutingRequest,
  createOutingTaskRequest,
  linkMailRequest,
  setOutingImageRequest,
  updateOutingRequest,
  updateOutingTaskRequest,
  updateTicketRequest,
} from '@burrow/contracts';
import {
  type Access,
  notFound,
  type PlatformEnv,
  requireRight,
} from '@burrow/platform';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { PictureError } from './pictures';
import { OutingError, type OutingsService } from './service';

const asHttp = (error: unknown): never => {
  if (error instanceof OutingError || error instanceof PictureError) {
    if (error.message === 'not found') throw notFound();
    throw new HTTPException(400, { message: error.message });
  }
  throw error;
};

const run = async <T>(fn: () => T | Promise<T>) => {
  try {
    return await fn();
  } catch (error) {
    return asHttp(error);
  }
};

// Tickets are what gets you in; a facts-only key never sees them.
const ticketsAllowed = (access: Access) => {
  if (access.factsOnly) {
    throw new HTTPException(403, { message: 'this key reads facts only' });
  }
};

// The household's outings. Reading needs `read`, changing `organize`;
// nothing here is owned by one person.
export function outingRoutes(outings: OutingsService) {
  return (
    new Hono<PlatformEnv>()
      .get('/outings', requireRight('read'), (c) =>
        c.json(outings.list(c.var.access)),
      )
      .post(
        '/outings',
        requireRight('organize'),
        zValidator('json', createOutingRequest),
        async (c) =>
          c.json(
            await run(() => outings.create(c.var.access, c.req.valid('json'))),
            201,
          ),
      )
      .get('/outings/:id', requireRight('read'), async (c) =>
        c.json(await run(() => outings.get(c.var.access, c.req.param('id')))),
      )
      .patch(
        '/outings/:id',
        requireRight('organize'),
        zValidator('json', updateOutingRequest),
        async (c) =>
          c.json(
            await run(() =>
              outings.update(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json'),
              ),
            ),
          ),
      )
      .delete('/outings/:id', requireRight('organize'), async (c) => {
        await run(() => outings.remove(c.req.param('id')));
        return c.body(null, 204);
      })
      // What Hedwig reads from a mail before it becomes an outing.
      .get('/messages/:id/outing', requireRight('read'), async (c) => {
        ticketsAllowed(c.var.access);
        return c.json(
          await run(() => outings.suggest(c.var.access, c.req.param('id'))),
        );
      })
      .post(
        '/outings/:id/tickets',
        requireRight('organize'),
        zValidator('json', addTicketRequest),
        async (c) => {
          ticketsAllowed(c.var.access);
          return c.json(
            await run(() =>
              outings.addTicket(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json'),
              ),
            ),
            201,
          );
        },
      )
      .patch(
        '/outings/:id/tickets/:ticketId',
        requireRight('organize'),
        zValidator('json', updateTicketRequest),
        async (c) =>
          c.json(
            await run(() =>
              outings.updateTicket(
                c.var.access,
                c.req.param('id'),
                c.req.param('ticketId'),
                c.req.valid('json'),
              ),
            ),
          ),
      )
      .delete(
        '/outings/:id/tickets/:ticketId',
        requireRight('organize'),
        async (c) =>
          c.json(
            await run(() =>
              outings.removeTicket(
                c.var.access,
                c.req.param('id'),
                c.req.param('ticketId'),
              ),
            ),
          ),
      )
      .get(
        '/outings/:id/tickets/:ticketId/file',
        requireRight('read'),
        async (c) => {
          ticketsAllowed(c.var.access);
          const { path, ticket } = await run(() =>
            outings.ticketFile(c.req.param('id'), c.req.param('ticketId')),
          );
          const size = await stat(path).then(
            (s) => s.size,
            () => {
              throw notFound();
            },
          );
          return new Response(
            Readable.toWeb(createReadStream(path)) as ReadableStream,
            {
              headers: {
                'content-type': ticket.contentType,
                'content-length': String(size),
                'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(ticket.name)}`,
                'x-content-type-options': 'nosniff',
                'cache-control': 'private, no-store',
              },
            },
          );
        },
      )
      .get('/outings/:id/image', requireRight('read'), async (c) => {
        const { path, contentType } = await run(() =>
          outings.pictures.file(c.req.param('id')),
        );
        return sendFile(path, contentType, 'private, max-age=86400');
      })
      .get('/outings/:id/image/options', requireRight('read'), async (c) => {
        ticketsAllowed(c.var.access);
        return c.json(
          await run(() => outings.pictures.options(c.req.param('id'))),
        );
      })
      .get(
        '/outings/:id/image/options/:optionId',
        requireRight('read'),
        async (c) => {
          ticketsAllowed(c.var.access);
          const { data, contentType } = await run(() =>
            outings.pictures.preview(
              c.req.param('id'),
              c.req.param('optionId'),
            ),
          );
          return new Response(data, { headers: imageHeaders(contentType) });
        },
      )
      .put(
        '/outings/:id/image',
        requireRight('organize'),
        zValidator('json', setOutingImageRequest),
        async (c) =>
          c.json(
            await run(() =>
              outings.setImage(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json'),
              ),
            ),
          ),
      )
      .delete('/outings/:id/image', requireRight('organize'), async (c) =>
        c.json(
          await run(() => outings.clearImage(c.var.access, c.req.param('id'))),
        ),
      )
      .post('/outings/:id/lineup', requireRight('organize'), async (c) =>
        c.json(
          await run(() =>
            outings.refreshLineup(c.var.access, c.req.param('id')),
          ),
        ),
      )
      .delete('/outings/:id/lineup', requireRight('organize'), async (c) =>
        c.json(
          await run(() =>
            outings.removeLineup(c.var.access, c.req.param('id')),
          ),
        ),
      )
      .post(
        '/outings/:id/tasks',
        requireRight('organize'),
        zValidator('json', createOutingTaskRequest),
        async (c) =>
          c.json(
            await run(() =>
              outings.addTask(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json'),
              ),
            ),
            201,
          ),
      )
      .patch(
        '/outings/:id/tasks/:taskId',
        requireRight('organize'),
        zValidator('json', updateOutingTaskRequest),
        async (c) =>
          c.json(
            await run(() =>
              outings.updateTask(
                c.var.access,
                c.req.param('id'),
                c.req.param('taskId'),
                c.req.valid('json'),
              ),
            ),
          ),
      )
      .delete(
        '/outings/:id/tasks/:taskId',
        requireRight('organize'),
        async (c) =>
          c.json(
            await run(() =>
              outings.removeTask(
                c.var.access,
                c.req.param('id'),
                c.req.param('taskId'),
              ),
            ),
          ),
      )
      .post(
        '/outings/:id/mails',
        requireRight('organize'),
        zValidator('json', linkMailRequest),
        async (c) =>
          c.json(
            await run(() =>
              outings.link(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').messageId,
              ),
            ),
          ),
      )
      .delete(
        '/outings/:id/mails/:messageId',
        requireRight('organize'),
        async (c) =>
          c.json(
            await run(() =>
              outings.unlink(
                c.var.access,
                c.req.param('id'),
                c.req.param('messageId'),
              ),
            ),
          ),
      )
  );
}

// A picture is shown, never run: no script even when opened directly.
function imageHeaders(contentType: string, cache = 'private, no-store') {
  return {
    'content-type': contentType,
    'x-content-type-options': 'nosniff',
    'content-security-policy': 'sandbox',
    'cache-control': cache,
  };
}

async function sendFile(path: string, contentType: string, cache: string) {
  const size = await stat(path).then(
    (s) => s.size,
    () => {
      throw notFound();
    },
  );
  return new Response(
    Readable.toWeb(createReadStream(path)) as ReadableStream,
    {
      headers: {
        ...imageHeaders(contentType, cache),
        'content-length': String(size),
      },
    },
  );
}
