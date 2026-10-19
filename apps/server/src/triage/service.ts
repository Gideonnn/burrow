import {
  type FilteredEntry,
  type TriageAction,
  type TriageDecision,
  type TriageStatus,
  triageDecision,
} from '@burrow/contracts';
import { describeOp, reverseOps, serverOpsFor } from '@burrow/hedwig';
import { and, desc, eq, inArray, isNull, like, lt, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AgentRunner } from '../agents/runner';
import type { Access } from '../auth/access';
import type { Catalog } from '../catalog/loadCatalog';
import type { Db } from '../db/client';
import {
  instructions,
  learnedRules,
  mailboxes,
  messages,
  people,
  triageLog,
} from '../db/schema';
import { type MailService, toSummary } from '../mail/service';
import { systemPrompt, triagePrompt } from './prompt';

const MAX_ATTEMPTS = 3;
const TRIAGE_SKILL = 'sorting-hat';
const decisionSchema = z.toJSONSchema(triageDecision, { target: 'draft-7' });

export class TriageError extends Error {}

export type TriageOptions = {
  db: Db;
  mail: MailService;
  runner: AgentRunner;
  catalog: Catalog;
  bot: string;
  language?: string;
  // Called after a decision was applied and recorded.
  onDecided?: (messageId: string, decision: TriageDecision) => void;
};

export class TriageService {
  private queue: Promise<void> = Promise.resolve();

  constructor(private readonly o: TriageOptions) {
    const bot = o.catalog.bots.get(o.bot);
    if (!bot) throw new TriageError(`unknown triage bot "${o.bot}"`);
    if (
      !bot.skills.includes(TRIAGE_SKILL) ||
      !o.catalog.skills.has(TRIAGE_SKILL)
    ) {
      throw new TriageError(
        `bot "${o.bot}" needs the ${TRIAGE_SKILL} skill to triage`,
      );
    }
    if (!bot.rights.includes('organize')) {
      throw new TriageError(
        `bot "${o.bot}" lacks the organize right it needs to triage`,
      );
    }
  }

  // Triage runs one message at a time: a household's mail does not need
  // parallel agent runs, and the laptop or mini-pc stays quiet.
  enqueue(messageIds: string[]): Promise<void> {
    for (const id of messageIds) {
      this.queue = this.queue.then(() =>
        this.triage(id).catch((error: Error) =>
          console.error(`triage of ${id} failed: ${error.message}`),
        ),
      );
    }
    return this.queue;
  }

  // Picks up inbox mail that arrived while triage was failing (agent CLI
  // logged out, quota), at most a few attempts per message.
  retryUntriaged(since = new Date(Date.now() - 2 * 86_400_000)): Promise<void> {
    const rows = this.o.db
      .select({ id: messages.id })
      .from(messages)
      .where(
        and(
          isNull(messages.triagedAt),
          eq(messages.folder, 'inbox'),
          lt(messages.triageAttempts, MAX_ATTEMPTS),
          sql`${messages.receivedAt} >= ${since.getTime()}`,
        ),
      )
      .all();
    return this.enqueue(rows.map((r) => r.id));
  }

  async triage(messageId: string): Promise<void> {
    const { db, mail, runner, catalog } = this.o;
    const message = mail.message(messageId);
    if (!message || message.triagedAt || message.folder !== 'inbox') return;
    const box = mail.mailbox(message.mailboxId)!;
    const owner = db
      .select()
      .from(people)
      .where(eq(people.id, box.ownerId))
      .get()!;
    const bot = catalog.bots.get(this.o.bot)!;

    db.update(messages)
      .set({ triageAttempts: message.triageAttempts + 1 })
      .where(eq(messages.id, message.id))
      .run();

    const raw = await runner.run({
      model: bot.model,
      // One skill per run, so instructions for other jobs cannot leak in.
      system: systemPrompt(bot, [catalog.skills.get(TRIAGE_SKILL)!]),
      prompt: triagePrompt({
        ownerName: owner.name,
        instructions: this.instructions(owner.id),
        rules: this.rules(owner.id).map((r) => r.text),
        mailbox: { address: box.address, provider: box.provider },
        message,
        ownerWroteToSender: this.ownerWroteTo(owner.id, message.from.email),
        language: this.o.language ?? 'English',
      }),
      schema: decisionSchema,
    });
    const decision: TriageDecision = triageDecision.parse(raw);
    const ops = serverOpsFor(decision.action);
    if (ops.length) await mail.apply(message.id, ops);

    db.transaction((tx) => {
      tx.insert(triageLog)
        .values({
          messageId: message.id,
          personId: owner.id,
          bot: bot.name,
          action: decision.action,
          reason: decision.reason,
          unsure: decision.unsure,
          ops,
          status: statusFor(decision.action),
        })
        .run();
      tx.update(messages)
        .set({ triagedAt: new Date() })
        .where(eq(messages.id, message.id))
        .run();
    });
    this.o.onDecided?.(message.id, decision);
  }

  // Filtered mail waiting for review, unsure ones first, limited to the
  // mailboxes the key can see.
  listFiltered(access: Access): FilteredEntry[] {
    if (!access.mailboxIds.length) return [];
    const rows = this.o.db
      .select({
        log: triageLog,
        message: messages,
        provider: mailboxes.provider,
      })
      .from(triageLog)
      .innerJoin(messages, eq(messages.id, triageLog.messageId))
      .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
      .where(
        and(
          eq(triageLog.status, 'pending-review'),
          inArray(messages.mailboxId, [...access.mailboxIds]),
        ),
      )
      .orderBy(desc(triageLog.unsure), desc(triageLog.createdAt))
      .all();
    return rows.map(({ log, message, provider }) => ({
      id: log.id,
      bot: log.bot,
      action: log.action,
      reason: log.reason,
      unsure: log.unsure,
      serverOps: log.ops.map((op) => describeOp(provider, op)),
      createdAt: log.createdAt.toISOString(),
      message: toSummary(message),
    }));
  }

  confirm(entryIds: string[], access: Access): number {
    let count = 0;
    for (const id of entryIds) {
      const entry = this.reviewable(id, access);
      if (!entry) continue;
      this.setStatus(entry.log.id, 'confirmed');
      count++;
    }
    return count;
  }

  confirmAll(access: Access): number {
    return this.confirm(
      this.listFiltered(access).map((e) => e.id),
      access,
    );
  }

  // Undoes the filter at the provider and turns the correction into a rule,
  // so the same sender is not filtered again.
  async restore(entryId: string, access: Access): Promise<void> {
    const entry = this.reviewable(entryId, access);
    if (!entry) throw new TriageError('not found');
    await this.o.mail.apply(entry.message.id, reverseOps(entry.log.ops));
    this.setStatus(entry.log.id, 'restored');
    const sender = entry.message.from.email;
    const text = `Keep mail from ${sender} in the inbox (it was filtered as ${entry.log.action.kind} and restored).`;
    const known = this.rules(entry.log.personId).some((r) =>
      r.text.includes(`from ${sender} `),
    );
    if (!known)
      this.o.db
        .insert(learnedRules)
        .values({ personId: entry.log.personId, text })
        .run();
  }

  instructions(personId: string): string {
    return (
      this.o.db
        .select()
        .from(instructions)
        .where(eq(instructions.personId, personId))
        .get()?.text ?? ''
    );
  }

  setInstructions(personId: string, text: string) {
    this.o.db
      .insert(instructions)
      .values({ personId, text })
      .onConflictDoUpdate({ target: instructions.personId, set: { text } })
      .run();
  }

  rules(personId: string) {
    return this.o.db
      .select()
      .from(learnedRules)
      .where(eq(learnedRules.personId, personId))
      .orderBy(learnedRules.createdAt)
      .all();
  }

  deleteRule(personId: string, id: string): boolean {
    const gone = this.o.db
      .delete(learnedRules)
      .where(and(eq(learnedRules.id, id), eq(learnedRules.personId, personId)))
      .returning()
      .all();
    return gone.length > 0;
  }

  private reviewable(id: string, access: Access) {
    const row = this.o.db
      .select({ log: triageLog, message: messages })
      .from(triageLog)
      .innerJoin(messages, eq(messages.id, triageLog.messageId))
      .where(eq(triageLog.id, id))
      .get();
    if (!row || row.log.status !== 'pending-review') return undefined;
    if (!access.mailboxIds.includes(row.message.mailboxId)) return undefined;
    return row;
  }

  private setStatus(id: string, status: TriageStatus) {
    this.o.db
      .update(triageLog)
      .set({ status, reviewedAt: new Date() })
      .where(eq(triageLog.id, id))
      .run();
  }

  private ownerWroteTo(personId: string, email: string): boolean {
    const needle = `%"email":${JSON.stringify(email)}%`;
    const hit = this.o.db
      .select({ id: messages.id })
      .from(messages)
      .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
      .where(
        and(
          eq(mailboxes.ownerId, personId),
          eq(messages.folder, 'sent'),
          like(messages.to, needle),
        ),
      )
      .limit(1)
      .get();
    return Boolean(hit);
  }
}

function statusFor(action: TriageAction): TriageStatus {
  switch (action.kind) {
    case 'spam':
    case 'archive':
      return 'pending-review';
    case 'keep':
      return 'kept';
    default:
      return 'applied';
  }
}
