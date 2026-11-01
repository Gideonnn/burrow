import {
  type FactCategory,
  type MessageSummary,
  type ShareAnswer,
  type ShareMode,
  type SharedResponse,
  type ShareSuggestion,
  shareAnswer,
  shareMode,
  type TaskResult,
} from '@burrow/contracts';
import {
  type Access,
  botRequest,
  listPeople,
  type Platform,
  shares,
  type StandingWork,
  type TaskKind,
  type TaskRow,
  untrusted,
} from '@burrow/platform';
import {
  and,
  count,
  desc,
  eq,
  gte,
  inArray,
  isNotNull,
  isNull,
  lt,
  ne,
  notInArray,
  or,
  type SQL,
  sql,
} from 'drizzle-orm';
import { z } from 'zod';
import { canSeeMailbox, readsShared } from './access';
import { textOf } from './facts/rules';
import { FACTS_FEATURE } from './facts/service';
import { summaries } from './facts/store';
import type { MailService, MessageRow } from './mail-service';
import {
  mailboxes,
  messageFacts,
  messages,
  shareSenders,
  shareSuggestions,
} from './schema';

export const SHARE_SETTING = 'hedwig.share';
const MODULE = 'hedwig';
const SHARE_SKILL = 'household-share';
const BATCH = 10;
const MAX_ATTEMPTS = 2;
const SILENCED_AFTER = 2;
const RECENT_MS = 183 * 86_400_000;
const LISTED = 200;
const FOLDERS = ['inbox', 'archive'] as const;
const NOT_HOUSEHOLD: FactCategory[] = [
  'code',
  'account',
  'promotion',
  'newsletter',
];
const answerSchema = z.toJSONSchema(shareAnswer, { target: 'draft-7' });

type Tx = Parameters<Parameters<Platform['db']['transaction']>[0]>[0];

export class SharingError extends Error {}

export type SharingOptions = {
  platform: Platform;
  mail: MailService;
  // The local bot that reads the mail; Winky.
  bot: string;
};

// Sharing one message with the rest of the household, and Winky's
// suggestions of household mail (energy, rent, bookings) to share. The share
// itself is the platform's `shares` row; who may read it is canSeeMessage.
export class SharingService {
  private readonly progressCache = new Map<
    string,
    { at: number; value: { waiting: number; done: number | null } }
  >();

  constructor(private readonly o: SharingOptions) {}

  private get db() {
    return this.o.platform.db;
  }

  private get shares() {
    return this.o.platform.shares;
  }

  mode(personId: string): ShareMode {
    const value = shareMode.safeParse(
      this.o.platform.settings.get(personId, SHARE_SETTING),
    );
    return value.success ? value.data : 'suggest';
  }

  private others(personId: string): string[] {
    return listPeople(this.db)
      .map((p) => p.id)
      .filter((id) => id !== personId);
  }

  // --- what a viewer sees -------------------------------------------------

  // Fills in `share` and `shareSuggestion` for the person looking.
  decorate<T extends MessageSummary>(viewerId: string, list: T[]): T[] {
    if (!list.length) return list;
    const ids = [...new Set(list.map((m) => m.id))];
    const sharedWith = new Map<string, string[]>();
    const open = new Map<string, string>();
    const suggests = this.mode(viewerId) !== 'off';
    for (let i = 0; i < ids.length; i += 500) {
      const chunk = ids.slice(i, i + 500);
      for (const s of this.db
        .select({ itemId: shares.itemId, personId: shares.personId })
        .from(shares)
        .where(and(eq(shares.module, MODULE), inArray(shares.itemId, chunk)))
        .all()) {
        sharedWith.set(s.itemId, [
          ...(sharedWith.get(s.itemId) ?? []),
          s.personId,
        ]);
      }
      if (!suggests) continue;
      for (const s of this.db
        .select({
          id: shareSuggestions.messageId,
          reason: shareSuggestions.reason,
        })
        .from(shareSuggestions)
        .where(
          and(
            inArray(shareSuggestions.messageId, chunk),
            eq(shareSuggestions.ownerId, viewerId),
            eq(shareSuggestions.state, 'open'),
          ),
        )
        .all()) {
        open.set(s.id, s.reason);
      }
    }
    const owners = new Map(
      this.db
        .select({ id: mailboxes.id, ownerId: mailboxes.ownerId })
        .from(mailboxes)
        .where(
          inArray(mailboxes.id, [...new Set(list.map((m) => m.mailboxId))]),
        )
        .all()
        .map((b) => [b.id, b.ownerId]),
    );
    return list.map((m) => {
      const owner = owners.get(m.mailboxId);
      const reason = open.get(m.id);
      return {
        ...m,
        share: {
          by: owner && owner !== viewerId ? owner : null,
          with: sharedWith.get(m.id) ?? [],
        },
        shareSuggestion: reason === undefined ? null : { reason },
      };
    });
  }

  // Ids of the messages shared with the key's person that a search
  // "everywhere" also looks in.
  sharedIds(access: Access): string[] {
    return readsShared(access)
      ? this.shares.sharedWith(MODULE, access.personId)
      : [];
  }

  shared(access: Access): SharedResponse {
    const withMeIds = this.sharedIds(access);
    const withMe = withMeIds.length
      ? this.db
          .select()
          .from(messages)
          .where(inArray(messages.id, withMeIds))
          .orderBy(desc(messages.receivedAt))
          .limit(LISTED)
          .all()
      : [];
    const byMe = access.mailboxIds.length
      ? this.db
          .selectDistinct({ m: messages })
          .from(messages)
          .innerJoin(
            shares,
            and(eq(shares.module, MODULE), eq(shares.itemId, messages.id)),
          )
          .where(inArray(messages.mailboxId, [...access.mailboxIds]))
          .orderBy(desc(messages.receivedAt))
          .limit(LISTED)
          .all()
          .map((r) => r.m)
      : [];
    return {
      withMe: this.view(access, withMe),
      byMe: this.view(access, byMe),
    };
  }

  suggestions(access: Access): ShareSuggestion[] {
    if (this.mode(access.personId) === 'off' || !access.mailboxIds.length)
      return [];
    const rows = this.db
      .select({ m: messages, reason: shareSuggestions.reason })
      .from(shareSuggestions)
      .innerJoin(messages, eq(messages.id, shareSuggestions.messageId))
      .where(
        and(
          eq(shareSuggestions.ownerId, access.personId),
          eq(shareSuggestions.state, 'open'),
          inArray(messages.mailboxId, [...access.mailboxIds]),
        ),
      )
      .orderBy(desc(messages.receivedAt))
      .limit(LISTED)
      .all();
    const views = this.view(
      access,
      rows.map((r) => r.m),
    );
    return views.map((message, i) => ({ message, reason: rows[i]!.reason }));
  }

  view(access: Access, rows: readonly MessageRow[]): MessageSummary[] {
    return this.decorate(access.personId, summaries(this.db, rows, access));
  }

  // --- what the owner does ------------------------------------------------

  private owned(access: Access, messageId: string) {
    const row = this.o.mail.message(messageId);
    if (!row || !canSeeMailbox(access, row.mailboxId)) {
      throw new SharingError('not found');
    }
    return { row, ownerId: this.o.mail.mailbox(row.mailboxId)!.ownerId };
  }

  share(access: Access, messageId: string, personId: string) {
    const { row, ownerId } = this.owned(access, messageId);
    if (personId === ownerId) {
      throw new SharingError('a message is already its owner’s');
    }
    if (!listPeople(this.db).some((p) => p.id === personId)) {
      throw new SharingError('unknown person');
    }
    this.db.transaction((tx) => {
      this.shares.share(MODULE, row.id, personId);
      const s = this.suggestion(tx, row.id);
      if (s?.suggested && s.state !== 'shared') {
        this.settle(tx, row, ownerId, 'shared');
        if (s.state === 'open')
          this.noteSender(tx, ownerId, row, { shared: 1 });
      }
    });
    this.changed(row, ownerId);
    return this.view(access, [row])[0]!;
  }

  // Taking back the last share of something Winky suggested counts as
  // turning the suggestion down.
  unshare(access: Access, messageId: string, personId: string) {
    const { row, ownerId } = this.owned(access, messageId);
    const before = this.shares.of(MODULE, row.id);
    this.db.transaction((tx) => {
      this.shares.unshare(MODULE, row.id, personId);
      const s = this.suggestion(tx, row.id);
      if (
        s?.state === 'shared' &&
        before.includes(personId) &&
        !this.shares.of(MODULE, row.id).length
      ) {
        this.settle(tx, row, ownerId, 'dismissed');
        this.noteSender(tx, ownerId, row, { dismissed: 1, always: false });
      }
    });
    this.changed(row, ownerId, before);
    return this.view(access, [row])[0]!;
  }

  decide(
    access: Access,
    messageId: string,
    decision: 'share' | 'dismiss',
    always: boolean,
  ) {
    const { row, ownerId } = this.owned(access, messageId);
    const s = this.suggestion(this.db, row.id);
    if (!s?.suggested || s.ownerId !== ownerId) {
      throw new SharingError('not found');
    }
    const sender = senderOf(row);
    const touched: MessageRow[] = [row];
    const household = this.others(ownerId);
    this.db.transaction((tx) => {
      // Always, from now on: also the open suggestions from the same sender.
      const alike =
        always && sender
          ? tx
              .select({ m: messages })
              .from(shareSuggestions)
              .innerJoin(messages, eq(messages.id, shareSuggestions.messageId))
              .where(
                and(
                  eq(shareSuggestions.ownerId, ownerId),
                  eq(shareSuggestions.state, 'open'),
                  ne(shareSuggestions.messageId, row.id),
                  sql`lower(json_extract(${messages.from}, '$.email')) = ${sender}`,
                ),
              )
              .all()
              .map((r) => r.m)
          : [];
      for (const m of [row, ...alike]) {
        if (decision === 'share') {
          for (const p of household) this.shares.share(MODULE, m.id, p);
          this.settle(tx, m, ownerId, 'shared');
        } else {
          this.settle(tx, m, ownerId, 'dismissed');
        }
      }
      touched.push(...alike);
      this.noteSender(
        tx,
        ownerId,
        row,
        decision === 'share'
          ? { shared: 1, ...(always ? { always: true } : {}) }
          : { dismissed: 1, always: false, silence: always },
      );
    });
    for (const m of touched) this.changed(m, ownerId);
    return this.view(access, [row])[0]!;
  }

  private suggestion(tx: Tx | Platform['db'], messageId: string) {
    return tx
      .select()
      .from(shareSuggestions)
      .where(eq(shareSuggestions.messageId, messageId))
      .get();
  }

  private settle(
    tx: Tx,
    m: MessageRow,
    ownerId: string,
    state: 'shared' | 'dismissed',
  ) {
    tx.update(shareSuggestions)
      .set({ state, decidedAt: new Date() })
      .where(
        and(
          eq(shareSuggestions.messageId, m.id),
          eq(shareSuggestions.ownerId, ownerId),
        ),
      )
      .run();
  }

  private noteSender(
    tx: Tx,
    ownerId: string,
    m: MessageRow,
    change: {
      shared?: number;
      dismissed?: number;
      always?: boolean;
      silence?: boolean;
    },
  ) {
    const address = senderOf(m);
    if (!address) return;
    const shared = change.shared ?? 0;
    const dismissed = change.dismissed ?? 0;
    tx.insert(shareSenders)
      .values({
        ownerId,
        address,
        shared,
        dismissed: change.silence
          ? Math.max(dismissed, SILENCED_AFTER)
          : dismissed,
        always: change.always ?? false,
        updatedAt: new Date(),
      })
      .onConflictDoUpdate({
        target: [shareSenders.ownerId, shareSenders.address],
        set: {
          shared: sql`${shareSenders.shared} + ${shared}`,
          dismissed: change.silence
            ? sql`max(${shareSenders.dismissed} + ${dismissed}, ${SILENCED_AFTER})`
            : sql`${shareSenders.dismissed} + ${dismissed}`,
          ...(change.always === undefined ? {} : { always: change.always }),
          updatedAt: new Date(),
        },
      })
      .run();
  }

  private changed(m: MessageRow, ownerId: string, also: string[] = []) {
    this.o.platform.events.emitTo(
      [...new Set([ownerId, ...also, ...this.shares.of(MODULE, m.id)])],
      { type: 'message.changed', mailboxId: m.mailboxId, messageId: m.id },
    );
  }

  // --- Winky --------------------------------------------------------------

  private active(personId: string) {
    return this.mode(personId) !== 'off' && this.others(personId).length > 0;
  }

  private waiting(personId: string, scope?: readonly string[]): SQL {
    // With facts on, Winky first writes the facts, so the summary and
    // category are there when he judges.
    const factsReady = this.o.platform.settings.enabled(personId, FACTS_FEATURE)
      ? or(
          ne(messageFacts.source, 'rules'),
          gte(messageFacts.modelAttempts, MAX_ATTEMPTS),
        )
      : undefined;
    return and(
      eq(mailboxes.ownerId, personId),
      scope ? inArray(messages.mailboxId, [...scope]) : undefined,
      inArray(messages.folder, [...FOLDERS]),
      gte(messages.receivedAt, new Date(Date.now() - RECENT_MS)),
      isNull(messageFacts.ruleCategory),
      or(
        isNull(messageFacts.category),
        notInArray(messageFacts.category, NOT_HOUSEHOLD),
      ),
      factsReady,
      or(
        isNull(shareSuggestions.messageId),
        and(
          isNull(shareSuggestions.judgedAt),
          lt(shareSuggestions.attempts, MAX_ATTEMPTS),
        ),
      ),
      sql`not exists (select 1 from ${shares} where ${shares.module} = ${MODULE} and ${shares.itemId} = ${messages.id})`,
      sql`not exists (select 1 from ${shareSenders} where ${shareSenders.ownerId} = ${personId} and ${shareSenders.address} = lower(json_extract(${messages.from}, '$.email')) and ${shareSenders.dismissed} >= ${SILENCED_AFTER} and ${shareSenders.always} = 0)`,
    )!;
  }

  private work: StandingWork = {
    people: () =>
      listPeople(this.db)
        .map((p) => p.id)
        .filter((id) => this.active(id)),
    progress: (personId) => {
      if (!this.active(personId)) return { waiting: 0, done: null };
      const cached = this.progressCache.get(personId);
      if (cached && Date.now() - cached.at < 30_000) return cached.value;
      const waiting = this.db
        .select({ n: count() })
        .from(messages)
        .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
        .innerJoin(messageFacts, eq(messageFacts.messageId, messages.id))
        .leftJoin(shareSuggestions, eq(shareSuggestions.messageId, messages.id))
        .where(this.waiting(personId))
        .get()!.n;
      const done = this.db
        .select({ n: count() })
        .from(shareSuggestions)
        .where(
          and(
            eq(shareSuggestions.ownerId, personId),
            isNotNull(shareSuggestions.judgedAt),
          ),
        )
        .get()!.n;
      // Someone with nothing to judge yet sees no row in the runner list.
      const value = { waiting, done: waiting || done ? done : null };
      this.progressCache.set(personId, { at: Date.now(), value });
      return value;
    },
    next: (personId, running, access) => {
      if (!this.active(personId)) return undefined;
      const held = running.flatMap((t) => this.ids(t));
      const scope = access?.restrictions.mailboxes
        ? access.mailboxIds
        : undefined;
      const ids = this.db
        .select({ id: messages.id })
        .from(messages)
        .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
        .innerJoin(messageFacts, eq(messageFacts.messageId, messages.id))
        .leftJoin(shareSuggestions, eq(shareSuggestions.messageId, messages.id))
        .where(
          and(
            this.waiting(personId, scope),
            held.length ? notInArray(messages.id, held) : undefined,
          ),
        )
        .orderBy(desc(messages.receivedAt))
        .limit(BATCH)
        .all()
        .map((r) => r.id);
      return ids.length ? { input: { messageIds: ids } } : undefined;
    },
  };

  private ids(task: TaskRow): string[] {
    return (task.input?.messageIds as string[] | undefined) ?? [];
  }

  private request(task: TaskRow) {
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot)!;
    const owner = this.o.platform.owner(task.personId);
    const others = listPeople(this.db)
      .filter((p) => p.id !== task.personId)
      .map((p) => p.name);
    const ids = this.ids(task);
    const rows = new Map(
      this.db
        .select({ m: messages, f: messageFacts })
        .from(messages)
        .leftJoin(messageFacts, eq(messageFacts.messageId, messages.id))
        .where(inArray(messages.id, ids))
        .all()
        .map((r) => [r.m.id, r]),
    );
    const parts = ids.map((id, i) => {
      const row = rows.get(id);
      if (!row) return `## Mail ${i + 1}\n(removed)`;
      const { m, f } = row;
      const from = m.from.name
        ? `${m.from.name} <${m.from.email}>`
        : m.from.email;
      return [
        `## Mail ${i + 1}`,
        untrusted(
          'untrusted_email',
          [
            `Date: ${m.receivedAt.toISOString().slice(0, 10)}`,
            `From: ${from}`,
            `Subject: ${m.subject}`,
            ...(f?.category ? [`Category: ${f.category}`] : []),
            ...(f?.summary ? [`Summary: ${f.summary}`] : []),
            '',
            textOf(m, 400),
          ].join('\n'),
        ),
      ].join('\n');
    });
    return {
      ...botRequest(bot, [catalog.skills.get(SHARE_SKILL)!]),
      prompt: [
        `${owner.name} shares a household with ${others.join(' and ')}.`,
        `Which of these ${ids.length} mails of ${owner.name} are household mail ${others.join(' and ')} should also see?`,
        `Write each reason in ${owner.language}.`,
        '',
        parts.join('\n\n'),
      ].join('\n'),
      schema: answerSchema,
      timeoutMs: 300_000,
    };
  }

  private apply(task: TaskRow, result: TaskResult) {
    const answer = shareAnswer.parse(JSON.parse(result.fields.answer!));
    const ids = this.ids(task);
    const answered = new Map<string, ShareAnswer['mails'][number]>();
    for (const a of answer.mails) {
      const id = ids[a.n - 1];
      if (id && !answered.has(id)) answered.set(id, a);
    }
    const ownerId = task.personId;
    const auto = this.mode(ownerId) === 'auto';
    const others = this.others(ownerId);
    const shared: MessageRow[] = [];
    const suggested: MessageRow[] = [];
    this.db.transaction((tx) => {
      for (const [id, a] of answered) {
        const m = this.o.mail.message(id);
        if (!m) continue;
        let state: 'open' | 'shared' | 'dismissed' | null = null;
        if (a.share) {
          const address = senderOf(m);
          const sender = address
            ? tx
                .select()
                .from(shareSenders)
                .where(
                  and(
                    eq(shareSenders.ownerId, ownerId),
                    eq(shareSenders.address, address),
                  ),
                )
                .get()
            : undefined;
          const silenced =
            !sender?.always && (sender?.dismissed ?? 0) >= SILENCED_AFTER;
          state = silenced
            ? 'dismissed'
            : auto || sender?.always
              ? 'shared'
              : 'open';
        }
        const values = {
          suggested: a.share,
          reason: a.reason.trim(),
          state,
          model: task.model,
          error: null,
          judgedAt: new Date(),
          decidedAt: state === 'shared' ? new Date() : null,
        };
        tx.insert(shareSuggestions)
          .values({ messageId: id, ownerId, ...values })
          .onConflictDoUpdate({
            target: shareSuggestions.messageId,
            set: values,
          })
          .run();
        if (state === 'shared') {
          for (const p of others) this.shares.share(MODULE, id, p);
          shared.push(m);
        } else if (state === 'open') {
          suggested.push(m);
        }
      }
    });
    this.progressCache.delete(ownerId);
    for (const m of [...shared, ...suggested]) this.changed(m, ownerId);
    this.failed(
      ownerId,
      ids.filter((id) => !answered.has(id)),
      'no answer for this mail',
    );
  }

  private failed(ownerId: string, ids: string[], error: string) {
    if (!ids.length) return;
    const existing = new Set(
      this.db
        .select({ id: messages.id })
        .from(messages)
        .where(inArray(messages.id, ids))
        .all()
        .map((r) => r.id),
    );
    this.db.transaction((tx) => {
      for (const id of ids) {
        if (!existing.has(id)) continue;
        tx.insert(shareSuggestions)
          .values({
            messageId: id,
            ownerId,
            attempts: 1,
            error: error.slice(0, 300),
          })
          .onConflictDoUpdate({
            target: shareSuggestions.messageId,
            set: {
              attempts: sql`${shareSuggestions.attempts} + 1`,
              error: error.slice(0, 300),
            },
          })
          .run();
      }
    });
  }

  kinds(): TaskKind[] {
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot);
    if (
      bot?.agent !== 'local' ||
      !bot.skills.includes(SHARE_SKILL) ||
      !catalog.skills.has(SHARE_SKILL)
    ) {
      return [];
    }
    return [
      {
        name: 'hedwig.share',
        title: 'Huishoudmail',
        queue: 'local',
        priority: 'low',
        model: bot.model,
        standing: this.work,
        describe: (t) => ({
          title: `Huishoudmail (${this.ids(t).length})`,
          bot: bot.name,
          skill: SHARE_SKILL,
        }),
        agent: {
          request: (t) => this.request(t),
          accept: (_t, raw) => answerResult(shareAnswer.parse(trim(raw))),
        },
        apply: async (t, result) => this.apply(t, result),
        failed: (t, error) => this.failed(t.personId, this.ids(t), error),
      },
    ];
  }
}

const senderOf = (m: Pick<MessageRow, 'from'>) =>
  m.from.email.trim().toLowerCase() || null;

function answerResult(answer: unknown): TaskResult {
  return {
    summary: 'Judged',
    fields: { answer: JSON.stringify(answer) },
    ops: [],
    draft: null,
  };
}

// Small models overshoot limits; a long reason is cut, not a failure.
function trim(raw: unknown): unknown {
  if (!raw || typeof raw !== 'object') return raw;
  const mails = (raw as { mails?: unknown }).mails;
  if (!Array.isArray(mails)) return raw;
  return {
    mails: mails
      .slice(0, 50)
      .map((m) =>
        m &&
        typeof m === 'object' &&
        typeof (m as { reason?: unknown }).reason === 'string'
          ? { ...m, reason: (m as { reason: string }).reason.slice(0, 60) }
          : m,
      ),
  };
}
