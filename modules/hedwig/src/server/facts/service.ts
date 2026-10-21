import {
  type FactCategory,
  type FactPriority,
  factsAnswer,
  type TaskResult,
  templatesAnswer,
} from '@burrow/contracts';
import {
  botRequest,
  listPeople,
  type Platform,
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
  inArray,
  isNotNull,
  isNull,
  lt,
  notInArray,
  or,
  sql,
} from 'drizzle-orm';
import { z } from 'zod';
import type { MailService, MessageRow } from '../mail-service';
import { mailboxes, messageFacts, messages, messageTemplates } from '../schema';
import {
  noise,
  RULES_VERSION,
  redact,
  redactCodes,
  sensitiveKinds,
  templateKey,
  textOf,
} from './rules';
import type { FactsRow } from './store';

export const FACTS_FEATURE = 'hedwig.facts';
const FACTS_SKILL = 'mail-facts';
const TEMPLATES_SKILL = 'mail-templates';
const MAX_ATTEMPTS = 2;
const TEMPLATE_MIN = 3;
const TEMPLATE_BATCH = 20;
// Spam and trash are not worth a model.
const INDEXED_FOLDERS = ['inbox', 'archive', 'sent'] as const;
const factsSchema = z.toJSONSchema(factsAnswer, { target: 'draft-7' });
const templatesSchema = z.toJSONSchema(templatesAnswer, { target: 'draft-7' });

type TemplateRow = typeof messageTemplates.$inferSelect;
type Tx = Parameters<Parameters<Platform['db']['transaction']>[0]>[0];

export type FactsOptions = {
  platform: Platform;
  mail: MailService;
  // Winky reads raw mail on the owner's Mac; Kreacher indexes templates on
  // Haiku from redacted examples.
  factsBot: string;
  templatesBot: string;
};

// Mail facts: fixed rules for every message, one Haiku answer per template
// of repeating mail, and a local model for the rest, for people with the
// feature on. Search and agents read the facts instead of the mail.
export class FactsService {
  // Per person, the template keys that got new members since the last look;
  // a person not grouped yet gets one full pass.
  private readonly dirty = new Map<string, Set<string>>();
  private readonly grouped = new Set<string>();
  private templatesOn = false;
  // Per person and key scope, the next messages for Winky, newest first, so
  // the backlog is not sorted again for every piece.
  private readonly backlog = new Map<string, string[]>();
  private readonly progressCache = new Map<
    string,
    { at: number; value: { waiting: number; done: number | null } }
  >();

  constructor(private readonly o: FactsOptions) {}

  private get db() {
    return this.o.platform.db;
  }

  private enabled(personId: string) {
    return this.o.platform.settings.enabled(personId, FACTS_FEATURE);
  }

  private featurePeople() {
    return listPeople(this.db)
      .map((p) => p.id)
      .filter((id) => this.enabled(id));
  }

  // --- rules --------------------------------------------------------------

  // Runs the rules over these messages, unless they already ran at this
  // version, and gives mail that matches a known template its facts.
  applyRules(messageIds: readonly string[]) {
    for (let i = 0; i < messageIds.length; i += 200) {
      const rows = this.db
        .select({ m: messages, owner: mailboxes.ownerId, f: messageFacts })
        .from(messages)
        .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
        .leftJoin(messageFacts, eq(messageFacts.messageId, messages.id))
        .where(inArray(messages.id, messageIds.slice(i, i + 200)))
        .all();
      this.db.transaction((tx) => {
        for (const { m, owner, f } of rows) {
          if (!f || f.rulesVersion < RULES_VERSION) {
            this.writeRules(tx, m, owner, f);
          }
        }
      });
    }
  }

  private writeRules(
    tx: Tx,
    m: MessageRow,
    personId: string,
    f: FactsRow | null,
  ) {
    const kinds = sensitiveKinds(`${m.subject}\n${textOf(m, 200_000)}`);
    if (f?.sensitiveKinds.includes('model')) kinds.push('model');
    const ruleCategory = noise(m.subject, textOf(m));
    const key = templateKey(m);
    const base = {
      rulesVersion: RULES_VERSION,
      sensitive: kinds.length > 0,
      sensitiveKinds: kinds,
      ruleCategory,
      templateKey: key,
      indexedAt: new Date(),
    };
    const byRules = {
      category: ruleCategory,
      priority: ruleCategory ? ('low' as const) : null,
    };
    if (f) {
      tx.update(messageFacts)
        .set({ ...base, ...(f.source === 'rules' ? byRules : {}) })
        .where(eq(messageFacts.messageId, m.id))
        .run();
    } else {
      const template = key
        ? tx
            .select()
            .from(messageTemplates)
            .where(
              and(
                eq(messageTemplates.personId, personId),
                eq(messageTemplates.key, key),
              ),
            )
            .get()
        : undefined;
      tx.insert(messageFacts)
        .values({
          messageId: m.id,
          personId,
          ...base,
          ...byRules,
          people: [],
          organisations: [],
          amounts: [],
          dates: [],
          keywords: [],
          source: 'rules',
          templateId:
            template && template.attempts < MAX_ATTEMPTS ? template.id : null,
          ...(template?.factsAt ? fromTemplate(template, ruleCategory) : {}),
        })
        .run();
    }
    if (key) {
      const keys = this.dirty.get(personId) ?? new Set<string>();
      keys.add(key);
      this.dirty.set(personId, keys);
    }
    if (!f) this.backlog.clear();
  }

  // Runs the rules over the whole archive in small steps, so the server
  // keeps answering meanwhile.
  async rulesPass(): Promise<number> {
    let total = 0;
    for (;;) {
      const ids = this.db
        .select({ id: messages.id })
        .from(messages)
        .leftJoin(messageFacts, eq(messageFacts.messageId, messages.id))
        .where(
          or(
            isNull(messageFacts.messageId),
            lt(messageFacts.rulesVersion, RULES_VERSION),
          ),
        )
        .limit(500)
        .all()
        .map((r) => r.id);
      if (!ids.length) return total;
      this.applyRules(ids);
      total += ids.length;
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  // --- templates ----------------------------------------------------------

  // Groups of at least three automated messages with the same sender and
  // subject pattern become templates; their members wait for the template's
  // answer instead of going to the local model.
  // Without a bot for templates the members go to Winky instead.
  private ensureTemplates(personId: string) {
    if (!this.templatesOn) return;
    const keys = this.dirty.get(personId);
    const full = !this.grouped.has(personId) || (keys?.size ?? 0) > 500;
    if (!full && !keys?.size) return;
    this.dirty.delete(personId);
    this.grouped.add(personId);
    const groups = this.db
      .select({ key: messageFacts.templateKey, n: count() })
      .from(messageFacts)
      .where(
        and(
          eq(messageFacts.personId, personId),
          full
            ? isNotNull(messageFacts.templateKey)
            : inArray(messageFacts.templateKey, [...keys!]),
        ),
      )
      .groupBy(messageFacts.templateKey)
      .having(sql`count(*) >= ${TEMPLATE_MIN}`)
      .all();
    this.db.transaction((tx) => {
      for (const { key, n } of groups) {
        const t = tx
          .insert(messageTemplates)
          .values({ personId, key: key!, members: n })
          .onConflictDoUpdate({
            target: [messageTemplates.personId, messageTemplates.key],
            set: { members: n },
          })
          .returning()
          .get();
        if (t.attempts >= MAX_ATTEMPTS) continue;
        if (t.factsAt) {
          applyTemplate(tx, t);
        } else {
          tx.update(messageFacts)
            .set({ templateId: t.id })
            .where(
              and(
                eq(messageFacts.personId, personId),
                eq(messageFacts.templateKey, t.key),
                isNull(messageFacts.templateId),
                isNull(messageFacts.modelAt),
              ),
            )
            .run();
        }
      }
    });
  }

  private templatesWork: StandingWork = {
    people: () => this.featurePeople(),
    progress: (personId) => {
      if (!this.enabled(personId)) return { waiting: 0, done: null };
      this.ensureTemplates(personId);
      const counts = this.db
        .select({ done: isNotNull(messageTemplates.factsAt), n: count() })
        .from(messageTemplates)
        .where(
          and(
            eq(messageTemplates.personId, personId),
            or(
              isNotNull(messageTemplates.factsAt),
              lt(messageTemplates.attempts, MAX_ATTEMPTS),
            ),
          ),
        )
        .groupBy(isNotNull(messageTemplates.factsAt))
        .all();
      return {
        waiting: Number(counts.find((c) => !c.done)?.n ?? 0),
        done: Number(counts.find((c) => c.done)?.n ?? 0),
      };
    },
    next: (personId, running, access) => {
      if (!this.enabled(personId)) return undefined;
      // A template spans mailboxes, so a key limited to some never gets one.
      if (access?.restrictions.mailboxes) return undefined;
      this.ensureTemplates(personId);
      const held = running.flatMap(
        (t) => (t.input?.templateIds as string[] | undefined) ?? [],
      );
      const rows = this.db
        .select({ id: messageTemplates.id })
        .from(messageTemplates)
        .where(
          and(
            eq(messageTemplates.personId, personId),
            isNull(messageTemplates.factsAt),
            lt(messageTemplates.attempts, MAX_ATTEMPTS),
            held.length ? notInArray(messageTemplates.id, held) : undefined,
          ),
        )
        .orderBy(desc(messageTemplates.members))
        .limit(TEMPLATE_BATCH)
        .all();
      return rows.length
        ? { input: { templateIds: rows.map((r) => r.id) } }
        : undefined;
    },
  };

  private templateIds(task: TaskRow): string[] {
    return (task.input?.templateIds as string[] | undefined) ?? [];
  }

  private templatesRequest(task: TaskRow) {
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.templatesBot)!;
    const owner = this.o.platform.owner(task.personId);
    const ids = this.templateIds(task);
    const byId = new Map(
      this.db
        .select()
        .from(messageTemplates)
        .where(inArray(messageTemplates.id, ids))
        .all()
        .map((t) => [t.id, t]),
    );
    const parts = ids.map((id, n) => {
      const t = byId.get(id);
      if (!t) return `## Group ${n}\n(removed)\n`;
      const [sender, pattern] = splitKey(t.key);
      const examples = this.db
        .select({ m: messages })
        .from(messageFacts)
        .innerJoin(messages, eq(messages.id, messageFacts.messageId))
        .where(
          and(
            eq(messageFacts.personId, t.personId),
            eq(messageFacts.templateKey, t.key),
            eq(messageFacts.sensitive, false),
          ),
        )
        .orderBy(desc(messages.receivedAt))
        .limit(2)
        .all()
        .map(
          ({ m }) =>
            `### Example\nSubject: ${redactCodes(m.subject)}\n\n${untrusted('untrusted_example', redactCodes(textOf(m, 1_500)))}`,
        );
      return [
        `## Group ${n}`,
        `Sender: ${sender}`,
        `Subject pattern: ${pattern}`,
        `Messages: ${t.members}`,
        '',
        ...examples,
      ].join('\n');
    });
    return {
      ...botRequest(bot, [catalog.skills.get(TEMPLATES_SKILL)!]),
      prompt: `Index these ${ids.length} groups of ${owner.name}'s mail. Write the summaries in ${owner.language}.\n\n${parts.join('\n\n')}`,
      schema: templatesSchema,
    };
  }

  private applyTemplates(task: TaskRow, result: TaskResult) {
    const answer = templatesAnswer.parse(JSON.parse(result.fields.answer!));
    const ids = this.templateIds(task);
    const answered = new Set<string>();
    this.db.transaction((tx) => {
      for (const a of answer.templates) {
        const id = ids[a.n];
        if (!id || answered.has(id)) continue;
        answered.add(id);
        const t = tx
          .update(messageTemplates)
          .set({
            category: a.category,
            priority: a.priority,
            summary: a.summary,
            organisation: a.organisation,
            keywords: a.keywords,
            model: task.model,
            factsAt: new Date(),
          })
          .where(eq(messageTemplates.id, id))
          .returning()
          .get();
        if (t) applyTemplate(tx, t);
      }
    });
    const missing = ids.filter((id) => !answered.has(id));
    if (missing.length) this.templatesFailed(missing);
  }

  // A template that keeps failing hands its members to the local model.
  private templatesFailed(ids: string[]) {
    if (!ids.length) return;
    this.db.transaction((tx) => {
      tx.update(messageTemplates)
        .set({ attempts: sql`${messageTemplates.attempts} + 1` })
        .where(inArray(messageTemplates.id, ids))
        .run();
      const given = tx
        .select({ id: messageTemplates.id })
        .from(messageTemplates)
        .where(
          and(
            inArray(messageTemplates.id, ids),
            isNull(messageTemplates.factsAt),
            sql`${messageTemplates.attempts} >= ${MAX_ATTEMPTS}`,
          ),
        )
        .all()
        .map((t) => t.id);
      if (given.length) {
        tx.update(messageFacts)
          .set({ templateId: null })
          .where(inArray(messageFacts.templateId, given))
          .run();
      }
    });
  }

  // --- the local model ----------------------------------------------------

  private waiting(personId: string) {
    return and(
      eq(messageFacts.personId, personId),
      isNull(messageFacts.modelAt),
      isNull(messageFacts.ruleCategory),
      isNull(messageFacts.templateId),
      lt(messageFacts.modelAttempts, MAX_ATTEMPTS),
      inArray(messages.folder, [...INDEXED_FOLDERS]),
    );
  }

  private factsWork: StandingWork = {
    people: () => this.featurePeople(),
    // Counting the backlog is a scan; runners ask after every piece.
    progress: (personId) => {
      if (!this.enabled(personId)) return { waiting: 0, done: null };
      const cached = this.progressCache.get(personId);
      if (cached && Date.now() - cached.at < 30_000) return cached.value;
      this.ensureTemplates(personId);
      const waiting = this.db
        .select({ n: count() })
        .from(messageFacts)
        .innerJoin(messages, eq(messages.id, messageFacts.messageId))
        .where(this.waiting(personId))
        .get()!.n;
      const done = this.db
        .select({ n: count() })
        .from(messageFacts)
        .where(
          and(
            eq(messageFacts.personId, personId),
            isNotNull(messageFacts.modelAt),
          ),
        )
        .get()!.n;
      const value = { waiting, done };
      this.progressCache.set(personId, { at: Date.now(), value });
      return value;
    },
    next: (personId, running, access) => {
      if (!this.enabled(personId)) return undefined;
      this.ensureTemplates(personId);
      const held = new Set(
        running.flatMap((t) => (t.subjectId ? [t.subjectId] : [])),
      );
      const scope = access?.restrictions.mailboxes
        ? access.mailboxIds
        : undefined;
      const key = `${personId}|${scope?.join(',') ?? '*'}`;
      let list = this.backlog.get(key) ?? [];
      for (let refill = 0; refill < 2; refill++) {
        while (list.length) {
          const id = list.shift()!;
          if (held.has(id) || !this.stillWaiting(personId, id, scope)) continue;
          this.backlog.set(key, list);
          return { subject: { type: 'message', id } };
        }
        list = this.loadBacklog(personId, held, scope);
        if (!list.length) break;
      }
      this.backlog.set(key, list);
      return undefined;
    },
  };

  private loadBacklog(
    personId: string,
    held: Set<string>,
    scope: readonly string[] | undefined,
  ): string[] {
    return this.db
      .select({ id: messageFacts.messageId })
      .from(messageFacts)
      .innerJoin(messages, eq(messages.id, messageFacts.messageId))
      .where(
        and(
          this.waiting(personId),
          scope ? inArray(messages.mailboxId, [...scope]) : undefined,
          held.size ? notInArray(messageFacts.messageId, [...held]) : undefined,
        ),
      )
      .orderBy(desc(messages.receivedAt))
      .limit(200)
      .all()
      .map((r) => r.id);
  }

  private stillWaiting(
    personId: string,
    id: string,
    scope: readonly string[] | undefined,
  ) {
    return Boolean(
      this.db
        .select({ id: messageFacts.messageId })
        .from(messageFacts)
        .innerJoin(messages, eq(messages.id, messageFacts.messageId))
        .where(
          and(
            eq(messageFacts.messageId, id),
            this.waiting(personId),
            scope ? inArray(messages.mailboxId, [...scope]) : undefined,
          ),
        )
        .get(),
    );
  }

  private factsRequest(task: TaskRow) {
    const { catalog } = this.o.platform;
    const m = task.subjectId ? this.o.mail.message(task.subjectId) : undefined;
    if (!m) throw new Error('the message is gone');
    const bot = catalog.bots.get(this.o.factsBot)!;
    const owner = this.o.platform.owner(task.personId);
    const who = (a: { name?: string; email: string }) =>
      a.name ? `${a.name} <${a.email}>` : a.email;
    return {
      ...botRequest(bot, [catalog.skills.get(FACTS_SKILL)!]),
      prompt: [
        `From: ${who(m.from)}`,
        `To: ${m.to.map(who).join(', ')}`,
        `Date: ${m.receivedAt.toISOString().slice(0, 10)}`,
        `Subject: ${m.subject}`,
        '',
        untrusted('untrusted_email', textOf(m)),
        '',
        `Write the summary in ${owner.language}.`,
      ].join('\n'),
      schema: factsSchema,
      timeoutMs: 300_000,
    };
  }

  private applyFacts(task: TaskRow, result: TaskResult) {
    const a = factsAnswer.parse(JSON.parse(result.fields.answer!));
    const f = this.db
      .select()
      .from(messageFacts)
      .where(eq(messageFacts.messageId, task.subjectId!))
      .get();
    if (!f) return;
    // The model can add the flag, never lift it.
    const added = a.sensitive && !f.sensitive;
    this.db
      .update(messageFacts)
      .set({
        category: f.ruleCategory ?? a.category,
        priority: f.ruleCategory ? 'low' : a.priority,
        // What the model wrote may quote a secret from the mail; facts reach
        // cloud agents and facts-only keys.
        summary: redact(a.summary),
        people: a.people.map(redact),
        organisations: a.organisations.map(redact),
        amounts: a.amounts,
        dates: a.dates,
        keywords: a.keywords.map(redact),
        sensitive: f.sensitive || a.sensitive,
        sensitiveKinds: added
          ? [...f.sensitiveKinds, 'model']
          : f.sensitiveKinds,
        source: 'model',
        model: task.model,
        modelAt: new Date(),
        modelError: null,
      })
      .where(eq(messageFacts.messageId, f.messageId))
      .run();
  }

  // --- task kinds ---------------------------------------------------------

  kinds(): TaskKind[] {
    const { catalog } = this.o.platform;
    const kinds: TaskKind[] = [];
    const factsBot = catalog.bots.get(this.o.factsBot);
    if (
      factsBot?.agent === 'local' &&
      factsBot.skills.includes(FACTS_SKILL) &&
      catalog.skills.has(FACTS_SKILL)
    ) {
      kinds.push({
        name: 'hedwig.facts',
        title: 'Mail-facts',
        queue: 'local',
        priority: 'low',
        model: factsBot.model,
        standing: this.factsWork,
        describe: () => ({
          title: 'Mail-facts',
          bot: factsBot.name,
          skill: FACTS_SKILL,
        }),
        agent: {
          request: (t) => this.factsRequest(t),
          accept: (_t, raw) => answerResult(factsAnswer.parse(trimFacts(raw))),
        },
        apply: async (t, result) => this.applyFacts(t, result),
        failed: (t, error) => {
          this.db
            .update(messageFacts)
            .set({
              modelAttempts: sql`${messageFacts.modelAttempts} + 1`,
              modelError: error.slice(0, 300),
            })
            .where(eq(messageFacts.messageId, t.subjectId ?? ''))
            .run();
        },
      });
    }
    const templatesBot = catalog.bots.get(this.o.templatesBot);
    if (
      templatesBot &&
      templatesBot.agent !== 'local' &&
      templatesBot.skills.includes(TEMPLATES_SKILL) &&
      catalog.skills.has(TEMPLATES_SKILL)
    ) {
      this.templatesOn = true;
      kinds.push({
        name: 'hedwig.templates',
        title: 'Mail-templates',
        queue: 'cloud',
        priority: 'normal',
        model: 'haiku',
        standing: this.templatesWork,
        describe: (t) => ({
          title: `Mail-templates (${this.templateIds(t).length})`,
          bot: templatesBot.name,
          skill: TEMPLATES_SKILL,
        }),
        agent: {
          request: (t) => this.templatesRequest(t),
          accept: (_t, raw) =>
            answerResult(templatesAnswer.parse(trimTemplates(raw))),
        },
        apply: async (t, result) => this.applyTemplates(t, result),
        failed: (t) => this.templatesFailed(this.templateIds(t)),
      });
    }
    return kinds;
  }
}

function splitKey(key: string): [string, string] {
  const at = key.indexOf('|');
  return [key.slice(0, at), key.slice(at + 1)];
}

function fromTemplate(t: TemplateRow, ruleCategory: FactCategory | null) {
  return {
    category: ruleCategory ?? t.category,
    priority: (ruleCategory ? 'low' : t.priority) as FactPriority | null,
    summary: t.summary,
    organisations: t.organisation ? [t.organisation] : [],
    keywords: t.keywords ?? [],
    source: 'template' as const,
    templateId: t.id,
  };
}

// Every member of the template without model facts gets its answer; a rule
// that recognised a code keeps its category.
function applyTemplate(tx: Tx, t: TemplateRow) {
  tx.update(messageFacts)
    .set({
      category: sql`coalesce(${messageFacts.ruleCategory}, ${t.category})`,
      priority: sql`case when ${messageFacts.ruleCategory} is null then ${t.priority} else 'low' end`,
      summary: t.summary,
      organisations: t.organisation ? [t.organisation] : [],
      keywords: t.keywords ?? [],
      source: 'template',
      templateId: t.id,
    })
    .where(
      and(
        eq(messageFacts.personId, t.personId),
        eq(messageFacts.templateKey, t.key),
        eq(messageFacts.source, 'rules'),
        isNull(messageFacts.modelAt),
      ),
    )
    .run();
}

// The answer travels to apply() inside the generic task result.
function answerResult(answer: unknown): TaskResult {
  return {
    summary: 'Indexed',
    fields: { answer: JSON.stringify(answer) },
    ops: [],
    draft: null,
  };
}

const cut = (value: unknown, max: number) =>
  typeof value === 'string' ? value.slice(0, max) : value;
const list = (value: unknown, max: number, each: (v: unknown) => unknown) =>
  Array.isArray(value) ? value.slice(0, max).map(each) : value;
const words = (value: unknown, max: number, length: number) =>
  list(value, max, (v) => cut(v, length));

// Small models overshoot limits; what is too long is cut instead of failing
// the whole answer.
function trimFacts(raw: unknown): unknown {
  if (!raw || typeof raw !== 'object') return raw;
  const r = raw as Record<string, unknown>;
  return {
    ...r,
    summary: cut(r.summary, 200),
    people: words(r.people, 10, 60),
    organisations: words(r.organisations, 10, 60),
    keywords: words(r.keywords, 15, 30),
    amounts: Array.isArray(r.amounts)
      ? r.amounts
          .filter(
            (a): a is { value: number; currency: string } =>
              typeof a?.value === 'number' && typeof a?.currency === 'string',
          )
          .slice(0, 5)
          .map((a) => ({ value: a.value, currency: a.currency.slice(0, 3) }))
      : r.amounts,
    dates: Array.isArray(r.dates)
      ? r.dates
          .filter(
            (d): d is string =>
              typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d),
          )
          .slice(0, 5)
      : r.dates,
  };
}

function trimTemplates(raw: unknown): unknown {
  if (!raw || typeof raw !== 'object') return raw;
  const r = raw as { templates?: unknown };
  return {
    templates: list(r.templates, 50, (t) => {
      if (!t || typeof t !== 'object') return t;
      const x = t as Record<string, unknown>;
      return {
        ...x,
        summary: cut(x.summary, 120),
        organisation: cut(x.organisation, 60),
        keywords: words(x.keywords, 15, 30),
      };
    }),
  };
}
