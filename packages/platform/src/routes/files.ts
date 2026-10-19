import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import type { PlatformEnv } from '../env';
import { FileError } from '../files';
import { requireRight } from '../middleware';

const createUpload = z.object({ size: z.number().int().positive() });
const chunkQuery = z.object({ offset: z.coerce.number().int().min(0) });

const asHttp = (error: unknown): never => {
  if (error instanceof FileError) {
    throw new HTTPException(error.message === 'unknown upload' ? 404 : 400, {
      message: error.message,
    });
  }
  throw error;
};

// Chunked uploads: create one with the total size, send the bytes in chunks
// of at most 32 MB with the offset each starts at, then hand the upload id to
// the module that wants the file (Pensieve: POST /pensieve/recordings).
export const fileRoutes = new Hono<PlatformEnv>()
  .post(
    '/uploads',
    requireRight('organize'),
    zValidator('json', createUpload),
    async (c) => {
      try {
        const upload = await c.var.platform.uploads.create(
          c.var.access.personId,
          c.req.valid('json').size,
        );
        return c.json(
          { id: upload.id, size: upload.size, received: upload.received },
          201,
        );
      } catch (error) {
        return asHttp(error);
      }
    },
  )
  .get('/uploads/:id', requireRight('organize'), (c) => {
    const upload = c.var.platform.uploads.get(
      c.req.param('id'),
      c.var.access.personId,
    );
    if (!upload) throw new HTTPException(404, { message: 'unknown upload' });
    return c.json({
      id: upload.id,
      size: upload.size,
      received: upload.received,
    });
  })
  .put(
    '/uploads/:id',
    requireRight('organize'),
    zValidator('query', chunkQuery),
    async (c) => {
      const body = c.req.raw.body;
      if (!body) throw new HTTPException(400, { message: 'empty chunk' });
      try {
        return c.json(
          await c.var.platform.uploads.append(
            c.req.param('id'),
            c.var.access.personId,
            c.req.valid('query').offset,
            body,
          ),
        );
      } catch (error) {
        return asHttp(error);
      }
    },
  );
