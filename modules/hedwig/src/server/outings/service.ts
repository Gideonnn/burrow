import { mkdir, rm, writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import {
  type AddTicketRequest,
  type CreateOutingRequest,
  type Outing,
  type OutingRead,
  outingRead,
  type OutingSuggestion,
  type OutingTask,
  type PersonRef,
  type SetOutingImageRequest,
  type UpdateOutingRequest,
} from '@burrow/contracts';
import {
  type Access,
  botRequest,
  type Platform,
  people,
} from '@burrow/platform';
import { and, asc, desc, eq, gt, like, lt, or } from 'drizzle-orm';
import { z } from 'zod';
import { factsFor } from '../facts/store';
import type { MailService, MessageRow } from '../mail-service';
import {
  mailboxes,
  messages,
  outingMessages,
  outingReads,
  outings,
  outingTasks,
  outingTickets,
} from '../schema';
import { type Detected, detectOuting, ticketLinks } from './detect';
import { type FetchPublic, fetchPublic } from './images';
import { LineupError, OutingLineups } from './lineup';
import { OutingPictures, PictureError } from './pictures';
import { OUTING_SKILL, readPrompt, withRead } from './reader';

export class OutingError extends Error {}

type OutingRow = typeof outings.$inferSelect;
type TaskRow = typeof outingTasks.$inferSelect;

const CONTENT_TYPES: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.pkpass': 'application/vnd.apple.pkpass',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.heic': 'image/heic',
  '.webp': 'image/webp',
};
const EXTENSIONS = Object.fromEntries(
  Object.entries(CONTENT_TYPES).map(([ext, type]) => [type, ext]),
);

const readSchema = z.toJSONSchema(outingRead, { target: 'draft-7' });
// Subjects worth a look when the archive is scanned at start.
const ORDER_SUBJECTS = [
  'ticket',
  'kaart',
  'bestelling',
  'order',
  'reservering',
  'kluis',
  'locker',
  'personali',
];
const ARCHIVE_DAYS = 400;
const ARCHIVE_MAX = 300;
// Mails per outing worth a look when it is enriched.
const ENRICH_MAX = 25;

const iso = (d: Date | null) => d?.toISOString() ?? null;
const at = (s: string | null | undefined) =>
  s === undefined ? undefined : s === null ? null : new Date(s);

// Outings are the household's, not one person's: everyone sees and changes
// them. Only the mails linked to an outing stay private to their mailbox.
export class OutingsService {
  private readonly reading = new Map<string, Promise<OutingRead | null>>();
  private readonly enriching = new Map<string, Promise<void>>();
  private readonly readerOn: boolean;
  readonly pictures: OutingPictures;
  readonly lineups: OutingLineups;

  constructor(
    private readonly o: {
      platform: Platform;
      mail: MailService;
      bot?: string;
      fetchPublic?: FetchPublic;
    },
  ) {
    this.pictures = new OutingPictures({
      platform: o.platform,
      mail: o.mail,
      fetch: o.fetchPublic ?? fetchPublic,
      dir: (id) => this.dir(id),
      picked: (id) => this.changed(id),
    });
    this.lineups = new OutingLineups({
      platform: o.platform,
      fetch: o.fetchPublic ?? fetchPublic,
      bot: o.bot,
      changed: (id) => this.changed(id),
    });
    const { catalog } = o.platform;
    const bot = o.bot ? catalog.bots.get(o.bot) : undefined;
    this.readerOn = Boolean(
      bot &&
      bot.agent !== 'local' &&
      bot.skills.includes(OUTING_SKILL) &&
      catalog.skills.has(OUTING_SKILL),
    );
  }

  private get db() {
    return this.o.platform.db;
  }

  list(access: Access): Outing[] {
    return this.db
      .select()
      .from(outings)
      .orderBy(asc(outings.startsAt))
      .all()
      .map((row) => this.toOuting(row, access));
  }

  get(access: Access, id: string): Outing {
    return this.toOuting(this.row(id), access);
  }

  // The outing a mail belongs to, if any.
  forMessage(access: Access, messageId: string): Outing | null {
    const link = this.db
      .select({ id: outingMessages.outingId })
      .from(outingMessages)
      .where(eq(outingMessages.messageId, messageId))
      .get();
    return link ? this.get(access, link.id) : null;
  }

  // Cheap enough to ask for every opened mail: the provider is only asked
  // for attachments when the mail looks like an outing.
  async suggest(access: Access, messageId: string): Promise<OutingSuggestion> {
    const message = this.visibleMessage(access, messageId);
    const outingId = this.forMessage(access, messageId)?.id ?? null;
    const found = await this.detect(message);
    if (!message.hasAttachments || (found.confidence === 'none' && !outingId)) {
      return { outingId, ...found };
    }
    const attachments = await this.o.mail
      .attachments(message.id)
      .catch(() => []);
    const { tickets } = detectOuting({ ...inputOf(message), attachments });
    return { outingId, ...found, tickets };
  }

  async create(access: Access, request: CreateOutingRequest): Promise<Outing> {
    const message = request.messageId
      ? this.visibleMessage(access, request.messageId)
      : undefined;
    const now = new Date();
    const id = crypto.randomUUID();
    const fields = {
      title: request.title,
      kind: request.kind ?? null,
      startsAt: new Date(request.startsAt),
      endsAt: at(request.endsAt) ?? null,
      doorsAt: at(request.doorsAt) ?? null,
      allDay: request.allDay ?? false,
      venue: request.venue ?? null,
      address: request.address ?? null,
      organiser: request.organiser ?? null,
      vendor: request.vendor ?? null,
      orderNumber: request.orderNumber ?? null,
      url: request.url ?? null,
      notes: request.notes ?? '',
      aliases: request.aliases ?? [],
      attendeeIds:
        request.attendeeIds?.map((p) => this.person(p)!) ?? this.everyone(),
    };
    this.db.transaction((tx) => {
      tx.insert(outings)
        .values({
          id,
          ...fields,
          searchText: searchText(fields),
          createdBy: access.personId,
          updatedBy: access.personId,
          updatedAt: now,
        })
        .run();
      if (request.personaliseBy) {
        tx.insert(outingTasks)
          .values({
            outingId: id,
            kind: 'personalise',
            title: 'Kaarten op naam zetten',
            dueAt: new Date(request.personaliseBy),
          })
          .run();
      }
      if (message) {
        tx.insert(outingMessages)
          .values({ outingId: id, messageId: message.id })
          .run();
      }
    });
    if (message) {
      for (const attachmentId of request.attachmentIds ?? []) {
        await this.addTicket(
          access,
          id,
          { messageId: message.id, attachmentId },
          false,
        );
      }
    }
    if (message || fields.url) void this.enrich(id);
    this.changed(id);
    return this.get(access, id);
  }

  update(access: Access, id: string, patch: UpdateOutingRequest): Outing {
    const row = this.row(id);
    const next = {
      ...patch,
      attendeeIds: patch.attendeeIds?.map((p) => this.person(p)!),
      startsAt: at(patch.startsAt) ?? undefined,
      endsAt: at(patch.endsAt),
      doorsAt: at(patch.doorsAt),
    };
    const merged = { ...row, ...stripUndefined(next) };
    this.db
      .update(outings)
      .set({
        ...stripUndefined(next),
        searchText: searchText(merged),
        updatedBy: access.personId,
        updatedAt: new Date(),
      })
      .where(eq(outings.id, id))
      .run();
    if (patch.inCalendar !== undefined) {
      this.db
        .update(outingTasks)
        .set(
          patch.inCalendar
            ? { doneAt: new Date(), doneBy: access.personId }
            : { doneAt: null, doneBy: null },
        )
        .where(
          and(eq(outingTasks.outingId, id), eq(outingTasks.kind, 'calendar')),
        )
        .run();
    }
    if (patch.url) void this.pictures.pickSoon(id);
    this.changed(id);
    return this.get(access, id);
  }

  // --- the picture --------------------------------------------------------

  async setImage(access: Access, id: string, request: SetOutingImageRequest) {
    await this.pictures.set(access, id, request).catch(asOutingError);
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  async clearImage(access: Access, id: string) {
    await this.pictures.clear(id).catch(asOutingError);
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  // --- the line-up --------------------------------------------------------

  refreshLineup(access: Access, id: string) {
    try {
      void this.lineups.refresh(id);
    } catch (error) {
      asOutingError(error);
    }
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  removeLineup(access: Access, id: string) {
    this.row(id);
    this.lineups.remove(id);
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  async remove(id: string) {
    this.row(id);
    this.db.delete(outings).where(eq(outings.id, id)).run();
    await rm(this.dir(id), { recursive: true, force: true });
    this.changed(id);
  }

  // --- tickets ------------------------------------------------------------

  async addTicket(
    access: Access,
    id: string,
    request: AddTicketRequest,
    notify = true,
  ) {
    this.row(id);
    const ticketId = crypto.randomUUID();
    const dir = await this.ensureDir(id);
    let name: string;
    let contentType: string;
    let size: number;
    let messageId: string | null = null;
    let file: string;
    if ('uploadId' in request) {
      name = request.name;
      contentType =
        CONTENT_TYPES[extname(name).toLowerCase()] ??
        'application/octet-stream';
      file = ticketId + (EXTENSIONS[contentType] ?? '');
      try {
        size = (
          await this.o.platform.uploads.take(
            request.uploadId,
            access.personId,
            join(dir, file),
          )
        ).size;
      } catch (error) {
        throw new OutingError((error as Error).message);
      }
    } else {
      const message = this.visibleMessage(access, request.messageId);
      const { meta, data } = await this.o.mail
        .attachment(message.id, request.attachmentId)
        .catch((error: Error) => {
          throw new OutingError(error.message);
        });
      name = meta.name;
      contentType = meta.contentType;
      size = data.byteLength;
      messageId = message.id;
      file =
        ticketId +
        (EXTENSIONS[contentType] ?? (extname(name).toLowerCase() || ''));
      await writeFile(join(dir, file), data);
      this.db
        .insert(outingMessages)
        .values({ outingId: id, messageId })
        .onConflictDoNothing()
        .run();
    }
    this.db
      .insert(outingTickets)
      .values({
        id: ticketId,
        outingId: id,
        name,
        contentType,
        size,
        file,
        messageId,
        addedBy: access.personId,
      })
      .run();
    this.touch(access, id);
    if (notify) this.changed(id);
    return this.get(access, id);
  }

  updateTicket(
    access: Access,
    id: string,
    ticketId: string,
    patch: { holder?: string | null; personalised?: boolean },
  ) {
    this.ticket(id, ticketId);
    this.db
      .update(outingTickets)
      .set(stripUndefined(patch))
      .where(eq(outingTickets.id, ticketId))
      .run();
    this.closePersonaliseWhenNamed(access, id);
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  async removeTicket(access: Access, id: string, ticketId: string) {
    const ticket = this.ticket(id, ticketId);
    this.db.delete(outingTickets).where(eq(outingTickets.id, ticketId)).run();
    await rm(join(this.dir(id), ticket.file), { force: true });
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  ticketFile(id: string, ticketId: string) {
    const ticket = this.ticket(id, ticketId);
    return { path: join(this.dir(id), ticket.file), ticket };
  }

  // --- checklist ----------------------------------------------------------

  addTask(
    access: Access,
    id: string,
    request: {
      title: string;
      dueAt?: string | null;
      assigneeId?: string | null;
    },
  ) {
    this.row(id);
    this.db
      .insert(outingTasks)
      .values({
        outingId: id,
        kind: 'custom',
        title: request.title,
        dueAt: at(request.dueAt) ?? null,
        assigneeId: this.person(request.assigneeId),
      })
      .run();
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  updateTask(
    access: Access,
    id: string,
    taskId: string,
    patch: {
      title?: string;
      dueAt?: string | null;
      assigneeId?: string | null;
      done?: boolean;
    },
  ) {
    this.task(id, taskId);
    this.db
      .update(outingTasks)
      .set(
        stripUndefined({
          title: patch.title,
          dueAt: at(patch.dueAt),
          assigneeId:
            patch.assigneeId === undefined
              ? undefined
              : this.person(patch.assigneeId),
          ...(patch.done === undefined
            ? {}
            : patch.done
              ? { doneAt: new Date(), doneBy: access.personId }
              : { doneAt: null, doneBy: null }),
        }),
      )
      .where(eq(outingTasks.id, taskId))
      .run();
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  removeTask(access: Access, id: string, taskId: string) {
    this.task(id, taskId);
    this.db.delete(outingTasks).where(eq(outingTasks.id, taskId)).run();
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  // --- mails --------------------------------------------------------------

  link(access: Access, id: string, messageId: string) {
    this.row(id);
    const message = this.visibleMessage(access, messageId);
    this.db
      .insert(outingMessages)
      .values({ outingId: id, messageId: message.id })
      .onConflictDoNothing()
      .run();
    this.touch(access, id);
    void this.enrich(id);
    this.changed(id);
    return this.get(access, id);
  }

  unlink(access: Access, id: string, messageId: string) {
    this.row(id);
    this.visibleMessage(access, messageId);
    this.db
      .delete(outingMessages)
      .where(
        and(
          eq(outingMessages.outingId, id),
          eq(outingMessages.messageId, messageId),
        ),
      )
      .run();
    this.touch(access, id);
    this.changed(id);
    return this.get(access, id);
  }

  // Order mails become outings by themselves, for whoever's mailbox they
  // arrived in: certain ones (schema.org) at once, likely ones when Haiku
  // reads tickets in them. A second mail about the same order or the same
  // night, a locker for it too, joins the existing outing.
  async adoptStored(ids: string[], now = new Date()) {
    for (const id of ids) {
      const message = this.o.mail.message(id);
      if (!message) continue;
      if (this.forMessage(this.ownerAccess(message.mailboxId), id)) continue;
      const input = inputOf(message);
      if (detectOuting(input).confidence === 'none') continue;
      const { found, read } = await this.detectWithRead(message);
      if (found.confidence === 'none' || !found.title || !found.startsAt)
        continue;
      // A guess of the rules alone waits for the Bewaar click.
      if (found.confidence === 'likely' && !read) continue;
      if (new Date(found.startsAt) < now) continue;
      const access = this.ownerAccess(message.mailboxId);
      const existing = this.sameOuting(
        found.orderNumber,
        found.title,
        new Date(found.startsAt),
      );
      if (existing) {
        this.db
          .insert(outingMessages)
          .values({ outingId: existing, messageId: id })
          .onConflictDoNothing()
          .run();
        this.changed(existing);
        void this.pictures.pickSoon(existing);
        continue;
      }
      // A locker or practical info alone is no outing.
      if (read?.about === 'addon' || read?.about === 'info') continue;
      const attachments = message.hasAttachments
        ? await this.o.mail.attachments(id).catch(() => [])
        : [];
      const { tickets } = detectOuting({ ...input, attachments });
      await this.create(access, {
        title: found.title,
        startsAt: found.startsAt,
        kind: found.kind,
        endsAt: found.endsAt,
        doorsAt: found.doorsAt,
        venue: found.venue,
        address: found.address,
        organiser: found.organiser,
        vendor: found.vendor,
        orderNumber: found.orderNumber,
        url: found.url && /^https?:/.test(found.url) ? found.url : null,
        aliases: found.aliases,
        personaliseBy: found.personaliseBy,
        messageId: id,
        attachmentIds: tickets.map((t) => t.id),
      }).catch((error: Error) =>
        console.error(
          `hedwig: could not keep outing from ${id}: ${error.message}`,
        ),
      );
    }
  }

  // Once at start: order mails already in the archive for nights still to
  // come. Only mail of the last year with JSON-LD or an order-like subject is
  // looked at, so this stays a quick scan; Haiku reads each mail only once.
  async adoptArchive(now = new Date()) {
    const since = new Date(now.getTime() - ARCHIVE_DAYS * 86_400_000);
    const ids = this.db
      .select({ id: messages.id })
      .from(messages)
      .where(
        and(
          gt(messages.receivedAt, since),
          or(
            like(messages.bodyHtml, '%ld+json%'),
            ...ORDER_SUBJECTS.map((w) => like(messages.subject, `%${w}%`)),
          ),
        ),
      )
      .orderBy(desc(messages.receivedAt))
      .limit(ARCHIVE_MAX)
      .all()
      .map((r) => r.id);
    await this.adoptStored(ids);
    for (const o of this.o.platform.db
      .select({ id: outings.id })
      .from(outings)
      .all()) {
      await this.enrich(o.id);
    }
    return ids.length;
  }

  // --- internals ----------------------------------------------------------

  private async detect(message: MessageRow): Promise<Detected> {
    return (await this.detectWithRead(message)).found;
  }

  private async detectWithRead(message: MessageRow) {
    const facts = factsFor(this.db, [message.id]).get(message.id);
    const found = detectOuting({ ...inputOf(message), dates: facts?.dates });
    if (found.confidence !== 'likely' || facts?.sensitive) {
      return { found, read: null };
    }
    const read = await this.read(message);
    return { found: read ? withRead(found, read) : found, read };
  }

  // Haiku reads what the rules only guess: the event's own name, its date,
  // and whether the mail is about tickets at all. Once per message; a failed
  // read is tried again next time.
  private read(message: MessageRow): Promise<OutingRead | null> {
    if (!this.readerOn) return Promise.resolve(null);
    const hit = this.db
      .select({ answer: outingReads.answer })
      .from(outingReads)
      .where(eq(outingReads.messageId, message.id))
      .get();
    if (hit) return Promise.resolve(hit.answer);
    let run = this.reading.get(message.id);
    if (!run) {
      run = this.readNow(message)
        .catch((error: Error) => {
          console.error(
            `hedwig: reading outing ${message.id} failed: ${error.message}`,
          );
          return null;
        })
        .finally(() => this.reading.delete(message.id));
      this.reading.set(message.id, run);
    }
    return run;
  }

  private async readNow(message: MessageRow): Promise<OutingRead> {
    const { catalog, runner } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot!)!;
    const request = {
      ...botRequest(bot, [catalog.skills.get(OUTING_SKILL)!]),
      prompt: readPrompt(message),
      schema: readSchema,
    };
    const answer = outingRead.parse(await runner.run(request));
    this.db
      .insert(outingReads)
      .values({ messageId: message.id, answer, model: request.model })
      .onConflictDoNothing()
      .run();
    return answer;
  }

  private sameOuting(
    orderNumber: string | null,
    title: string,
    startsAt: Date,
  ) {
    const rows = this.db.select().from(outings).all();
    const day = (d: Date) => d.toISOString().slice(0, 10);
    return rows.find(
      (o) =>
        (orderNumber && o.orderNumber === orderNumber) ||
        (sameEvent(o.title, title) && day(o.startsAt) === day(startsAt)),
    )?.id;
  }

  // Mails about the same night in every mailbox of the household: the
  // order, reminders, lockers and practical info. Haiku reads each once; what
  // they say fills what the outing still misses, never what someone typed.
  enrich(id: string): Promise<void> {
    let run = this.enriching.get(id);
    if (!run) {
      run = this.enrichNow(id)
        .catch((error: Error) =>
          console.error(
            `hedwig: enriching outing ${id} failed: ${error.message}`,
          ),
        )
        .finally(() => this.enriching.delete(id));
      this.enriching.set(id, run);
    }
    return run;
  }

  private async enrichNow(id: string) {
    const row = this.db.select().from(outings).where(eq(outings.id, id)).get();
    if (!row) return;
    const phrase = searchPhrase(row.title);
    const linked = new Set(
      this.db
        .select({ id: outingMessages.messageId })
        .from(outingMessages)
        .where(eq(outingMessages.outingId, id))
        .all()
        .map((r) => r.id),
    );
    if (this.readerOn && phrase) {
      const day = 86_400_000;
      const t = row.startsAt.getTime();
      const candidates = this.db
        .select({ id: messages.id })
        .from(messages)
        .where(
          and(
            gt(messages.receivedAt, new Date(t - 400 * day)),
            lt(messages.receivedAt, new Date(t + 14 * day)),
            or(
              like(messages.subject, `%${phrase}%`),
              like(messages.bodyText, `%${phrase}%`),
              row.orderNumber
                ? like(messages.bodyText, `%${row.orderNumber}%`)
                : undefined,
            ),
          ),
        )
        .orderBy(desc(messages.receivedAt))
        .limit(ENRICH_MAX)
        .all()
        .map((r) => r.id)
        .filter((m) => !linked.has(m));
      for (const messageId of candidates) {
        const message = this.o.mail.message(messageId);
        if (!message || this.isSensitive(messageId)) continue;
        const read = await this.read(message);
        if (
          !read ||
          !['tickets', 'addon', 'info'].includes(read.about) ||
          !read.title ||
          !sameEvent(read.title, row.title)
        )
          continue;
        this.db
          .insert(outingMessages)
          .values({ outingId: id, messageId })
          .onConflictDoNothing()
          .run();
        linked.add(messageId);
      }
    }
    const reads = (
      await Promise.all(
        [...linked].map((m) => {
          const message = this.o.mail.message(m);
          return message && !this.isSensitive(m) ? this.read(message) : null;
        }),
      )
    ).filter((r): r is OutingRead => Boolean(r));
    const fill = fillFrom(row, reads);
    if (Object.keys(fill).length) {
      const merged = { ...row, ...fill };
      this.db
        .update(outings)
        .set({ ...fill, searchText: searchText(merged) })
        .where(eq(outings.id, id))
        .run();
    }
    await this.pictures.pickSoon(id);
    this.changed(id);
  }

  // Only the order mail itself, not news or practical info, points to the
  // tickets; mail without a reading is an order the rules were sure of.
  private aboutTickets(messageId: string) {
    const read = this.db
      .select({ answer: outingReads.answer })
      .from(outingReads)
      .where(eq(outingReads.messageId, messageId))
      .get();
    return !read || read.answer.about === 'tickets';
  }

  private isSensitive(messageId: string) {
    return Boolean(factsFor(this.db, [messageId]).get(messageId)?.sensitive);
  }

  // What Hedwig itself may do in a mailbox's owner's name.
  private ownerAccess(mailboxId: string): Access {
    const owner = this.o.mail.mailbox(mailboxId)!.ownerId;
    return {
      keyId: 'hedwig',
      keyName: 'Hedwig',
      personId: owner,
      rights: new Set(['read', 'organize']),
      restrictions: {},
      factsOnly: false,
      mailboxIds: [mailboxId],
    } as Access;
  }

  private everyone(): string[] {
    return this.db
      .select({ id: people.id })
      .from(people)
      .all()
      .map((p) => p.id);
  }

  private row(id: string): OutingRow {
    const row = this.db.select().from(outings).where(eq(outings.id, id)).get();
    if (!row) throw new OutingError('not found');
    return row;
  }

  private ticket(id: string, ticketId: string) {
    const ticket = this.db
      .select()
      .from(outingTickets)
      .where(
        and(eq(outingTickets.id, ticketId), eq(outingTickets.outingId, id)),
      )
      .get();
    if (!ticket) throw new OutingError('not found');
    return ticket;
  }

  private task(id: string, taskId: string): TaskRow {
    const task = this.db
      .select()
      .from(outingTasks)
      .where(and(eq(outingTasks.id, taskId), eq(outingTasks.outingId, id)))
      .get();
    if (!task) throw new OutingError('not found');
    return task;
  }

  private person(id: string | null | undefined): string | null {
    if (!id) return null;
    const row = this.db
      .select({ id: people.id })
      .from(people)
      .where(eq(people.id, id))
      .get();
    if (!row) throw new OutingError('unknown person');
    return row.id;
  }

  private visibleMessage(access: Access, messageId: string) {
    const message = this.o.mail.message(messageId);
    if (!message || !access.mailboxIds.includes(message.mailboxId)) {
      throw new OutingError('not found');
    }
    return message;
  }

  // Once every ticket has a name or is marked personalised, the deadline is met.
  private closePersonaliseWhenNamed(access: Access, id: string) {
    const tickets = this.db
      .select()
      .from(outingTickets)
      .where(eq(outingTickets.outingId, id))
      .all();
    if (!tickets.length || !tickets.every((t) => t.personalised)) return;
    this.db
      .update(outingTasks)
      .set({ doneAt: new Date(), doneBy: access.personId })
      .where(
        and(eq(outingTasks.outingId, id), eq(outingTasks.kind, 'personalise')),
      )
      .run();
  }

  private touch(access: Access, id: string) {
    this.db
      .update(outings)
      .set({ updatedBy: access.personId, updatedAt: new Date() })
      .where(eq(outings.id, id))
      .run();
  }

  // Both Macs refresh their list; the event says only which outing changed.
  private changed(id: string) {
    this.o.platform.events.emit({
      data: { type: 'outing.changed', outingId: id },
      visibleTo: (a) => a.rights.has('read'),
    });
  }

  private dir(id: string) {
    return this.o.platform.files.path('hedwig', 'outings', id);
  }

  private ensureDir(id: string) {
    return mkdir(this.dir(id), { recursive: true }).then(() => this.dir(id));
  }

  private toOuting(row: OutingRow, access: Access): Outing {
    const names = this.names();
    const ref = (id: string): PersonRef => ({
      id,
      name: names.get(id) ?? 'Onbekend',
    });
    const tickets = this.db
      .select()
      .from(outingTickets)
      .where(eq(outingTickets.outingId, row.id))
      .orderBy(asc(outingTickets.addedAt))
      .all();
    const tasks = this.db
      .select()
      .from(outingTasks)
      .where(eq(outingTasks.outingId, row.id))
      .orderBy(asc(outingTasks.createdAt))
      .all();
    const mails = this.db
      .select({ m: messages, ownerId: mailboxes.ownerId })
      .from(outingMessages)
      .innerJoin(messages, eq(messages.id, outingMessages.messageId))
      .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
      .where(eq(outingMessages.outingId, row.id))
      .orderBy(asc(messages.receivedAt))
      .all();
    return {
      id: row.id,
      title: row.title,
      kind: row.kind,
      startsAt: row.startsAt.toISOString(),
      endsAt: iso(row.endsAt),
      doorsAt: iso(row.doorsAt),
      allDay: row.allDay,
      venue: row.venue,
      address: row.address,
      organiser: row.organiser,
      vendor: row.vendor,
      orderNumber: row.orderNumber,
      url: row.url,
      notes: row.notes,
      aliases: row.aliases,
      inCalendar: row.inCalendar,
      image:
        row.imageType && row.imageSource && row.imageAt
          ? {
              source: row.imageSource,
              contentType: row.imageType,
              updatedAt: row.imageAt.toISOString(),
            }
          : null,
      tickets: tickets.map((t) => ({
        id: t.id,
        name: t.name,
        contentType: t.contentType,
        size: t.size,
        holder: t.holder,
        personalised: t.personalised,
        messageId: t.messageId,
        addedBy: ref(t.addedBy),
        addedAt: t.addedAt.toISOString(),
      })),
      tasks: tasks.map((t): OutingTask => ({
        id: t.id,
        kind: t.kind,
        title: t.title,
        dueAt: iso(t.dueAt),
        assignee: t.assigneeId ? ref(t.assigneeId) : null,
        doneAt: iso(t.doneAt),
        doneBy: t.doneBy ? ref(t.doneBy) : null,
      })),
      mails: mails.map(({ m, ownerId }) => {
        const visible =
          access.mailboxIds.includes(m.mailboxId) && !access.factsOnly;
        return {
          id: m.id,
          visible,
          owner: ref(ownerId),
          subject: visible ? m.subject : null,
          from: visible ? m.from : null,
          receivedAt: m.receivedAt.toISOString(),
        };
      }),
      lineup: lineupOf(this.lineups.get(row.id)),
      ticketLinks: access.factsOnly
        ? []
        : mails
            .filter(({ m }) => this.aboutTickets(m.id))
            .flatMap(({ m }) =>
              ticketLinks(m.bodyHtml).map((url) => ({
                url,
                label: linkLabel(row.vendor, url),
                messageId: m.id,
              })),
            ),
      attendees: row.attendeeIds.filter((p) => names.has(p)).map(ref),
      createdBy: ref(row.createdBy),
      createdAt: row.createdAt.toISOString(),
      updatedBy: ref(row.updatedBy),
      updatedAt: row.updatedAt.toISOString(),
    };
  }

  private names() {
    return new Map(
      this.db
        .select({ id: people.id, name: people.name })
        .from(people)
        .all()
        .map((p) => [p.id, p.name]),
    );
  }
}

// Every name of an outing in one lower-case string, for mail search.
export function searchText(o: {
  title: string;
  kind: string | null;
  venue: string | null;
  organiser: string | null;
  vendor: string | null;
  orderNumber: string | null;
  aliases: string[];
}) {
  return [
    o.title,
    o.kind,
    o.venue,
    o.organiser,
    o.vendor,
    o.orderNumber,
    ...o.aliases,
  ]
    .filter(Boolean)
    .join(' | ')
    .toLowerCase();
}

function stripUndefined<T extends Record<string, unknown>>(o: T) {
  return Object.fromEntries(
    Object.entries(o).filter(([, v]) => v !== undefined),
  ) as { [K in keyof T]: Exclude<T[K], undefined> };
}

function inputOf(message: MessageRow) {
  return {
    subject: message.subject,
    from: message.from,
    bodyText: message.bodyText,
    bodyHtml: message.bodyHtml,
    receivedAt: message.receivedAt,
    hasAttachments: message.hasAttachments,
    attachments: [],
  };
}

function asOutingError(error: unknown): never {
  if (error instanceof PictureError || error instanceof LineupError) {
    throw new OutingError(error.message);
  }
  throw error;
}

// One event under two names: "Hoge Bomen Festival 2026 - De Finale" and
// "Hoge Bomen Festival", or "Welcome To The 90s 2026" and "Welcome To The 90's".
function sameEvent(a: string, b: string) {
  const plain = (s: string) =>
    s
      .toLowerCase()
      .replace(/\b(19|20)\d{2}\b/g, '')
      .replace(/[^\p{L}\p{N}]+/gu, '');
  const [x, y] = [plain(a), plain(b)];
  return Boolean(x && y) && (x.includes(y) || y.includes(x));
}

// The start of a title to find other mails about it by: "Hoge Bomen Festival
// 2026 - De Finale" searches "Hoge Bomen Festival".
function searchPhrase(title: string) {
  const head = title.split(/\s[-|:–]\s/)[0]!;
  const words = head
    .split(/\s+/)
    .map((w) => w.replace(/[^\p{L}\p{N}].*$/u, ''))
    .filter((w) => w && !/^(19|20)\d{2}$/.test(w));
  const out: string[] = [];
  for (const w of words) {
    out.push(w);
    if (out.length >= 2 && out.join('').length >= 10) break;
    if (out.length >= 4) break;
  }
  const phrase = out.join(' ');
  return phrase.length >= 5 ? phrase : null;
}

// What the readings of an outing's mails add to it: only empty fields, and a
// time for a day without one.
function fillFrom(row: OutingRow, reads: OutingRead[]) {
  const first = <T>(pick: (r: OutingRead) => T | null) => {
    for (const r of reads) {
      const v = pick(r);
      if (v) return v;
    }
    return null;
  };
  const sameDay = (r: OutingRead) =>
    r.title && sameEvent(r.title, row.title) ? r : null;
  const time = (value: string | null) =>
    value && value.length > 10 && !Number.isNaN(new Date(value).getTime())
      ? new Date(value)
      : null;
  const fill: Partial<OutingRow> = {};
  const set = <K extends keyof OutingRow>(
    key: K,
    value: OutingRow[K] | null,
  ) => {
    if (row[key] == null && value != null) fill[key] = value as OutingRow[K];
  };
  set(
    'venue',
    first((r) => r.venue),
  );
  set(
    'address',
    first((r) => r.city),
  );
  set(
    'organiser',
    first((r) => r.organiser),
  );
  set(
    'kind',
    first((r) => r.kind),
  );
  set(
    'orderNumber',
    first((r) => r.orderNumber),
  );
  set(
    'url',
    first((r) =>
      r.website && /^https?:\/\//.test(r.website) ? r.website : null,
    ),
  );
  const day = row.startsAt.toDateString();
  set(
    'doorsAt',
    first((r) => {
      const d = time(sameDay(r)?.doorsAt ?? null);
      return d && d.toDateString() === day ? d : null;
    }),
  );
  set(
    'endsAt',
    first((r) => {
      const d = time(sameDay(r)?.endsAt ?? null);
      return d && d > row.startsAt ? d : null;
    }),
  );
  if (row.allDay) {
    const start = first((r) => {
      const d = time(sameDay(r)?.startsAt ?? null);
      return d && d.toDateString() === day ? d : null;
    });
    if (start) {
      fill.startsAt = start;
      fill.allDay = false;
    }
  }
  return fill;
}

// "Kaartjes bij Weeztix", by the shop's name or else the link's host.
function linkLabel(vendor: string | null, url: string) {
  if (vendor) return `Kaartjes bij ${vendor}`;
  const host = new URL(url).hostname
    .replace(/^(www|order|shop|tickets?|account)\./, '')
    .split('.')[0]!;
  return `Kaartjes bij ${host.charAt(0).toUpperCase()}${host.slice(1)}`;
}

function lineupOf(row: ReturnType<OutingLineups['get']>) {
  if (!row) return null;
  return {
    status: row.status,
    error: row.error,
    artists: row.artists,
    complete: row.complete,
    note: row.note,
    sources: row.sources,
    updatedAt: row.updatedAt.toISOString(),
  };
}
