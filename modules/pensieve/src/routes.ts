import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { Readable } from 'node:stream';
import {
  createRecordingRequest,
  labelRequest,
  recordingKind,
  redoRequest,
  setLabelsRequest,
  setMarksRequest,
  shareRequest,
  updateRecordingRequest,
} from '@burrow/contracts';
import { notFound, type PlatformEnv, requireRight } from '@burrow/platform';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';
import { RecordingError, type Recordings } from './recordings';

const listQuery = z.object({
  scope: z.enum(['all', 'mine', 'shared']).default('all'),
  q: z.string().trim().min(1).max(200).optional(),
  kind: recordingKind.optional(),
});

const asHttp = (error: unknown): never => {
  if (error instanceof RecordingError) {
    if (error.message === 'not found') throw notFound();
    throw new HTTPException(400, { message: error.message });
  }
  throw error;
};

// Recordings of the key's person and those shared with them. Changing,
// sharing or deleting is for the owner only; someone a recording was shared
// with can read and listen.
export function pensieveRoutes(recordings: Recordings) {
  return (
    new Hono<PlatformEnv>()
      .get(
        '/pensieve/recordings',
        requireRight('read'),
        zValidator('query', listQuery),
        (c) => {
          const { scope, q, kind } = c.req.valid('query');
          // Repeated: ?label=Werk&label=Thuis matches either.
          const labels = (c.req.queries('label') ?? [])
            .map((l) => l.trim())
            .filter(Boolean);
          const filter = { scope, kind, labels };
          return c.json(
            q
              ? recordings.search(c.var.access, q, filter)
              : recordings.list(c.var.access, filter),
          );
        },
      )
      .get('/pensieve/labels', requireRight('read'), (c) =>
        c.json(recordings.listLabels(c.var.access)),
      )
      .post(
        '/pensieve/labels',
        requireRight('organize'),
        zValidator('json', labelRequest),
        (c) =>
          c.json(
            recordings.addLabel(c.var.access, c.req.valid('json').name),
            201,
          ),
      )
      .patch(
        '/pensieve/labels/:id',
        requireRight('organize'),
        zValidator('json', labelRequest),
        (c) => {
          try {
            return c.json(
              recordings.renameLabel(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').name,
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .delete('/pensieve/labels/:id', requireRight('organize'), (c) => {
        try {
          recordings.removeLabel(c.var.access, c.req.param('id'));
        } catch (error) {
          asHttp(error);
        }
        return c.json({ deleted: true });
      })
      .post(
        '/pensieve/recordings',
        requireRight('organize'),
        zValidator('json', createRecordingRequest),
        async (c) => {
          try {
            return c.json(
              await recordings.create(c.var.access, c.req.valid('json')),
              201,
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .get('/pensieve/recordings/:id', requireRight('read'), (c) => {
        const row = recordings.find(c.var.access, c.req.param('id'));
        if (!row) throw notFound();
        return c.json(recordings.detail(row, c.var.access));
      })
      // Streams the stored audio with Range support, so players can seek.
      .get(
        '/pensieve/recordings/:id/audio',
        requireRight('read'),
        async (c) => {
          const row = recordings.find(c.var.access, c.req.param('id'));
          const path = row && recordings.audioPath(row);
          if (!path) throw notFound();
          const { size } = await stat(path);
          const range = /^bytes=(\d*)-(\d*)$/.exec(c.req.header('range') ?? '');
          let start = 0;
          let end = size - 1;
          if (range) {
            start = range[1]
              ? Number(range[1])
              : Math.max(0, size - Number(range[2]));
            end =
              range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : end;
            if (start > end || start >= size) {
              return c.body(null, 416, { 'content-range': `bytes */${size}` });
            }
          }
          const body = Readable.toWeb(
            createReadStream(path, { start, end }),
          ) as ReadableStream;
          return new Response(body, {
            status: range ? 206 : 200,
            headers: {
              'content-type': 'audio/mp4',
              'content-length': String(end - start + 1),
              'accept-ranges': 'bytes',
              ...(range
                ? { 'content-range': `bytes ${start}-${end}/${size}` }
                : {}),
            },
          });
        },
      )
      .patch(
        '/pensieve/recordings/:id',
        requireRight('organize'),
        zValidator('json', updateRecordingRequest),
        (c) => {
          try {
            return c.json(
              recordings.rename(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').title,
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .delete(
        '/pensieve/recordings/:id',
        requireRight('organize'),
        async (c) => {
          try {
            await recordings.remove(c.var.access, c.req.param('id'));
          } catch (error) {
            asHttp(error);
          }
          return c.json({ deleted: true });
        },
      )
      .post(
        '/pensieve/recordings/:id/share',
        requireRight('organize'),
        zValidator('json', shareRequest),
        (c) => {
          try {
            return c.json(
              recordings.share(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').personId,
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .delete(
        '/pensieve/recordings/:id/share/:personId',
        requireRight('organize'),
        (c) => {
          try {
            return c.json(
              recordings.unshare(
                c.var.access,
                c.req.param('id'),
                c.req.param('personId'),
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .put(
        '/pensieve/recordings/:id/labels',
        requireRight('organize'),
        zValidator('json', setLabelsRequest),
        (c) => {
          try {
            return c.json(
              recordings.setLabels(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').labels,
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .put(
        '/pensieve/recordings/:id/marks',
        requireRight('organize'),
        zValidator('json', setMarksRequest),
        (c) => {
          try {
            return c.json(
              recordings.setMarks(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').marks,
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .post(
        '/pensieve/recordings/:id/transcribe',
        requireRight('organize'),
        (c) => {
          try {
            return c.json(
              recordings.requestTranscript(c.var.access, c.req.param('id')),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
      .get('/pensieve/recordings/:id/subtitles', requireRight('read'), (c) => {
        const row = recordings.find(c.var.access, c.req.param('id'));
        const srt = row && recordings.subtitles(row);
        if (!srt) throw notFound();
        return c.body(srt, 200, {
          'content-type': 'application/x-subrip; charset=utf-8',
        });
      })
      .post(
        '/pensieve/recordings/:id/redo',
        requireRight('organize'),
        zValidator('json', redoRequest),
        (c) => {
          try {
            return c.json(
              recordings.redo(
                c.var.access,
                c.req.param('id'),
                c.req.valid('json').step,
              ),
            );
          } catch (error) {
            return asHttp(error);
          }
        },
      )
  );
}
