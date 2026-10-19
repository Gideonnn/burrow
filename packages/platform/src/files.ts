import { createWriteStream } from 'node:fs';
import { mkdir, rename, rm, stat, truncate } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { and, eq, lt } from 'drizzle-orm';
import type { Db } from './db';
import { uploads } from './schema';

export class FileError extends Error {}

// Large files live on disk under the data directory, one folder per module;
// the database only holds their names.
export class Files {
  readonly root: string;

  constructor(dataDir: string) {
    this.root = resolve(dataDir, 'files');
  }

  // A path inside the module's folder; refuses anything that would escape it.
  path(module: string, ...parts: string[]): string {
    const base = resolve(this.root, module);
    const full = resolve(base, ...parts);
    if (full !== base && !full.startsWith(base + sep)) {
      throw new FileError('path outside the module folder');
    }
    return full;
  }

  async ensureDir(module: string, ...parts: string[]) {
    const dir = this.path(module, ...parts);
    await mkdir(dir, { recursive: true });
    return dir;
  }
}

// Cloudflare caps one request at 100 MB, so big files arrive in chunks. Each
// chunk names the offset it starts at; a client that lost its connection asks
// how much arrived and continues from there.
export const MAX_UPLOAD = 4 * 1024 ** 3;
export const MAX_CHUNK = 32 * 1024 ** 2;
const STALE_MS = 2 * 86_400_000;

export class Uploads {
  private readonly dir: string;

  constructor(
    private readonly db: Db,
    dataDir: string,
  ) {
    this.dir = resolve(dataDir, 'uploads');
  }

  async create(personId: string, size: number) {
    if (!Number.isInteger(size) || size < 1 || size > MAX_UPLOAD) {
      throw new FileError(`size must be between 1 byte and ${MAX_UPLOAD}`);
    }
    await mkdir(this.dir, { recursive: true });
    return this.db.insert(uploads).values({ personId, size }).returning().get();
  }

  get(id: string, personId: string) {
    return this.db
      .select()
      .from(uploads)
      .where(and(eq(uploads.id, id), eq(uploads.personId, personId)))
      .get();
  }

  async append(
    id: string,
    personId: string,
    offset: number,
    body: ReadableStream<Uint8Array>,
  ) {
    const upload = this.get(id, personId);
    if (!upload) throw new FileError('unknown upload');
    if (offset !== upload.received) {
      throw new FileError(`expected offset ${upload.received}`);
    }
    const file = this.partPath(id);
    let written = 0;
    const limit = Math.min(MAX_CHUNK, upload.size - upload.received);
    const counter = new Transform({
      transform(chunk: Buffer, _encoding, done) {
        written += chunk.length;
        if (written > limit) done(new FileError('chunk too large'));
        else done(null, chunk);
      },
    });
    try {
      await pipeline(
        Readable.fromWeb(body as never),
        counter,
        createWriteStream(file, { flags: 'a' }),
      );
    } catch (error) {
      // Cut the file back to what was acknowledged, so a retry starts clean.
      await truncateTo(file, upload.received);
      throw error;
    }
    const received = upload.received + written;
    this.db.update(uploads).set({ received }).where(eq(uploads.id, id)).run();
    return { received, size: upload.size, complete: received === upload.size };
  }

  // Hands a complete upload to a module: moves the file to `target` and
  // forgets the upload.
  async take(id: string, personId: string, target: string) {
    const upload = this.get(id, personId);
    if (!upload) throw new FileError('unknown upload');
    if (upload.received !== upload.size) {
      throw new FileError('the upload is not complete');
    }
    await rename(this.partPath(id), target);
    this.db.delete(uploads).where(eq(uploads.id, id)).run();
    return upload;
  }

  // Uploads nobody finished within two days.
  async sweep(now = new Date()) {
    const stale = this.db
      .delete(uploads)
      .where(lt(uploads.createdAt, new Date(now.getTime() - STALE_MS)))
      .returning()
      .all();
    for (const u of stale) await rm(this.partPath(u.id), { force: true });
  }

  private partPath(id: string) {
    if (!/^[0-9a-f-]{36}$/.test(id)) throw new FileError('unknown upload');
    return join(this.dir, `${id}.part`);
  }
}

async function truncateTo(file: string, size: number) {
  const current = await stat(file).catch(() => undefined);
  if (current && current.size > size) await truncate(file, size);
}
