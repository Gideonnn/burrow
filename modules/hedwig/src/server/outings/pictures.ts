import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type {
  OutingImageOptions,
  SetOutingImageRequest,
} from '@burrow/contracts';
import type { Access, Platform } from '@burrow/platform';
import { eq } from 'drizzle-orm';
import type { MailService } from '../mail-service';
import { messages, outingMessages, outings } from '../schema';
import {
  type FetchPublic,
  fitsAbove,
  IMAGE_EXTENSIONS,
  type ImageCandidate,
  type ImageRef,
  MAX_IMAGE_BYTES,
  mailImages,
  measure,
  pageImages,
  pageLimit,
} from './images';

const OPTIONS_TTL_MS = 10 * 60_000;
// Enough to find the picture without fetching a whole newsletter.
const PICK_TRIES = 8;

export class PictureError extends Error {}

type Picture = { data: Uint8Array; contentType: string };

// The picture above an outing: picked by Hedwig from its mails or website,
// or chosen by someone. Only the server fetches, so no sender sees the Macs.
export class OutingPictures {
  private readonly picking = new Map<string, Promise<void>>();
  private readonly cache = new Map<
    string,
    { at: number; list: ImageCandidate[] }
  >();

  constructor(
    private readonly o: {
      platform: Platform;
      mail: MailService;
      fetch: FetchPublic;
      dir: (id: string) => string;
      picked: (id: string) => void;
    },
  ) {}

  private get db() {
    return this.o.platform.db;
  }

  async file(id: string): Promise<{ path: string; contentType: string }> {
    const row = this.row(id);
    if (!row.imageType) throw new PictureError('not found');
    return {
      path: join(this.o.dir(id), `image${IMAGE_EXTENSIONS[row.imageType]}`),
      contentType: row.imageType,
    };
  }

  async options(id: string): Promise<OutingImageOptions> {
    const list = await this.candidates(id);
    return {
      options: list.map((c) => ({ id: optionId(c.ref), source: c.source })),
    };
  }

  async preview(id: string, option: string): Promise<Picture> {
    return this.load(await this.option(id, option));
  }

  async set(access: Access, id: string, request: SetOutingImageRequest) {
    this.row(id);
    if ('optionId' in request) {
      const c = await this.option(id, request.optionId);
      await this.store(id, await this.load(c), c.source);
    } else if ('uploadId' in request) {
      await mkdir(this.o.dir(id), { recursive: true });
      const incoming = join(this.o.dir(id), 'incoming');
      try {
        await this.o.platform.uploads.take(
          request.uploadId,
          access.personId,
          incoming,
        );
        const data = await readFile(incoming);
        if (data.byteLength > MAX_IMAGE_BYTES) {
          throw new PictureError('the picture is larger than 8 MB');
        }
        await this.store(id, picture(data), 'upload');
      } catch (error) {
        throw new PictureError((error as Error).message);
      } finally {
        await rm(incoming, { force: true });
      }
    } else {
      await this.store(id, await this.fromLink(request.url), 'website');
    }
  }

  async clear(id: string) {
    this.row(id);
    await this.removeFiles(id);
    this.db
      .update(outings)
      .set({
        imageType: null,
        imageSource: null,
        imageAt: new Date(),
        imageOff: true,
      })
      .where(eq(outings.id, id))
      .run();
  }

  // Looks for a picture in the background when the outing has none yet;
  // tests await the returned promise.
  pickSoon(id: string): Promise<void> {
    let run = this.picking.get(id);
    if (!run) {
      run = this.pick(id)
        .catch((error: Error) =>
          console.error(
            `hedwig: no picture for outing ${id}: ${error.message}`,
          ),
        )
        .finally(() => this.picking.delete(id));
      this.picking.set(id, run);
    }
    return run;
  }

  // The largest picture that fits above an outing, from its mails first and
  // its website after.
  private async pick(id: string) {
    const row = this.db.select().from(outings).where(eq(outings.id, id)).get();
    if (!row || row.imageType || row.imageOff) return;
    this.cache.delete(id);
    let best: { p: Picture; source: ImageCandidate['source']; area: number } = {
      p: { data: new Uint8Array(), contentType: '' },
      source: 'mail',
      area: 0,
    };
    for (const c of (await this.candidates(id)).slice(0, PICK_TRIES)) {
      const p = await this.load(c).catch(() => undefined);
      const size = p && measure(p.data);
      if (!p || !size || !fitsAbove(size)) continue;
      const area = size.width * size.height;
      if (area > best.area) best = { p, source: c.source, area };
    }
    if (!best.area) return;
    const now = this.row(id);
    if (now.imageType || now.imageOff) return;
    await this.store(id, best.p, best.source);
    this.o.picked(id);
  }

  private async candidates(id: string): Promise<ImageCandidate[]> {
    const hit = this.cache.get(id);
    if (hit && Date.now() - hit.at < OPTIONS_TTL_MS) return hit.list;
    const row = this.row(id);
    const list: ImageCandidate[] = [];
    const add = (c: ImageCandidate) => {
      const key = optionId(c.ref);
      if (!list.some((x) => optionId(x.ref) === key)) list.push(c);
    };
    const mails = this.db
      .select({ m: messages })
      .from(outingMessages)
      .innerJoin(messages, eq(messages.id, outingMessages.messageId))
      .where(eq(outingMessages.outingId, id))
      .all();
    for (const { m } of mails) {
      for (const url of mailImages(m.bodyHtml)) {
        add({ source: 'mail', ref: { url } });
      }
      if (!m.hasAttachments) continue;
      const attachments = await this.o.mail.attachments(m.id).catch(() => []);
      for (const a of attachments) {
        if (a.inline && a.contentType.startsWith('image/')) {
          add({
            source: 'mail',
            ref: { messageId: m.id, attachmentId: a.id },
          });
        }
      }
    }
    if (row.url && /^https?:\/\//.test(row.url)) {
      const page = await this.o
        .fetch(row.url, pageLimit)
        .catch(() => undefined);
      if (page?.contentType === 'text/html') {
        const html = Buffer.from(page.data).toString('utf8');
        for (const url of pageImages(html, page.url)) {
          add({ source: 'website', ref: { url } });
        }
      }
    }
    this.cache.set(id, { at: Date.now(), list });
    return list;
  }

  private async option(id: string, option: string) {
    const c = (await this.candidates(id)).find(
      (x) => optionId(x.ref) === option,
    );
    if (!c) throw new PictureError('not found');
    return c;
  }

  private async load(c: ImageCandidate): Promise<Picture> {
    const ref: ImageRef = c.ref;
    if ('url' in ref) {
      const { data } = await this.o.fetch(ref.url, MAX_IMAGE_BYTES);
      return picture(data);
    }
    const { data } = await this.o.mail.attachment(
      ref.messageId,
      ref.attachmentId,
    );
    if (data.byteLength > MAX_IMAGE_BYTES) {
      throw new PictureError('the picture is larger than 8 MB');
    }
    return picture(data);
  }

  // A link someone copied: the picture itself, or a page that offers one.
  private async fromLink(url: string): Promise<Picture> {
    const fetched = await this.o
      .fetch(url, Math.max(MAX_IMAGE_BYTES, pageLimit))
      .catch((error: Error) => {
        throw new PictureError(`could not fetch the link: ${error.message}`);
      });
    if (measure(fetched.data)) return picture(fetched.data);
    if (fetched.contentType !== 'text/html') {
      throw new PictureError('the link is not a picture');
    }
    const html = Buffer.from(fetched.data).toString('utf8');
    for (const image of pageImages(html, fetched.url)) {
      const p = await this.o
        .fetch(image, MAX_IMAGE_BYTES)
        .then((f) => picture(f.data))
        .catch(() => undefined);
      if (p) return p;
    }
    throw new PictureError('the page has no picture to share');
  }

  private async store(
    id: string,
    p: Picture,
    source: 'mail' | 'website' | 'upload',
  ) {
    await this.removeFiles(id);
    await mkdir(this.o.dir(id), { recursive: true });
    await writeFile(
      join(this.o.dir(id), `image${IMAGE_EXTENSIONS[p.contentType]}`),
      p.data,
    );
    this.db
      .update(outings)
      .set({
        imageType: p.contentType,
        imageSource: source,
        imageAt: new Date(),
        imageOff: false,
      })
      .where(eq(outings.id, id))
      .run();
  }

  private async removeFiles(id: string) {
    const names = await readdir(this.o.dir(id)).catch(() => []);
    for (const name of names) {
      if (name.startsWith('image.')) await rm(join(this.o.dir(id), name));
    }
  }

  private row(id: string) {
    const row = this.db.select().from(outings).where(eq(outings.id, id)).get();
    if (!row) throw new PictureError('not found');
    return row;
  }
}

// Only PNG, JPEG, GIF and WebP are kept; SVG could carry script.
function picture(data: Uint8Array): Picture {
  const size = measure(data);
  if (!size) throw new PictureError('not a picture Hedwig can show');
  return { data, contentType: size.contentType };
}

function optionId(ref: ImageRef) {
  return createHash('sha256')
    .update(JSON.stringify(ref))
    .digest('base64url')
    .slice(0, 16);
}
