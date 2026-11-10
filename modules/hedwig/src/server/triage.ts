import {
  type FilteredEntry,
  type RuleKind,
  type ServerOp,
  type TriageAction,
  type TriageDecision,
  type TriageStatus,
  triageDecision,
} from '@burrow/contracts';
import { type Access, type Platform, botRequest } from '@burrow/platform';
import { and, desc, eq, inArray, isNull, like, lt, sql } from 'drizzle-orm';
import { z } from 'zod';
import { describeOp, restoreOps, serverOpsFor } from '../server-ops';
import { forKey } from './facts/store';
import { type MailService, type MessageRow, toSummary } from './mail-service';
import { triagePrompt } from './prompt';
import { learnedRules, mailboxes, messages, triageLog } from './schema';
import {
  authenticationFailed,
  type RuleScope,
  ruleTarget,
  senderReason,
} from './sender-rules';

const MAX_ATTEMPTS = 3;
const TRIAGE_SKILL = 'sorting-hat';
const decisionSchema = z.toJSONSchema(triageDecision, { target: 'draft-7' });

class TriageError extends Error {}

export type TriageOptions = {
  platform: Platform;
  mail: MailService;
  bot: string;
  // Called after a decision was applied and recorded.
  onDecided?: (messageId: string, decision: TriageDecision) => void;
};

export class TriageService {
  private queue: Promise<void> = Promise.resolve();

  constructor(private readonly o: TriageOptions) {
    const { catalog } = o.platform;
    const bot = catalog.bots.get(o.bot);
    if (!bot) throw new TriageError(`unknown triage bot "${o.bot}"`);
    if (
      !bot.skills.includes(TRIAGE_SKILL) ||
      !catalog.skills.has(TRIAGE_SKILL)
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
    const rows = this.o.platform.db
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
    const { mail, platform } = this.o;
    const { db, runner, catalog } = platform;
    const message = mail.message(messageId);
    if (!message || message.triagedAt || message.folder !== 'inbox') return;
    const box = mail.mailbox(message.mailboxId)!;
    // A person who switched sorting off keeps their inbox as it arrives.
    if (!platform.settings.enabled(box.ownerId, 'hedwig.triage')) return;
    const owner = platform.owner(box.ownerId);
    const bot = catalog.bots.get(this.o.bot)!;

    db.update(messages)
      .set({ triageAttempts: message.triageAttempts + 1 })
      .where(eq(messages.id, message.id))
      .run();

    const rule = this.senderRule(box.ownerId, message.from.email);
    let decision: TriageDecision;
    if (rule?.kind === 'spam') {
      decision = {
        action: { kind: 'spam' },
        reason: senderReason('spam', rule.sender!, owner.language),
        unsure: false,
      };
    } else {
      const raw = await runner.run({
        ...botRequest(bot, [catalog.skills.get(TRIAGE_SKILL)!]),
        prompt: triagePrompt({
          ownerName: owner.name,
          instructions: owner.instructions,
          mailboxInstructions: box.instructions,
          rules: this.rules(box.ownerId).map((r) => r.text),
          mailbox: { address: box.address, provider: box.provider },
          message,
          ownerWroteToSender: this.ownerWroteTo(
            box.ownerId,
            message.from.email,
          ),
          language: owner.language,
        }),
        schema: decisionSchema,
      });
      decision = triageDecision.parse(raw);
      // A forged sender stays the bot's to judge.
      if (
        decision.action.kind === 'spam' &&
        rule?.kind === 'not-spam' &&
        !authenticationFailed(message.headers)
      ) {
        decision = {
          action: { kind: 'keep' },
          reason: senderReason('not-spam', rule.sender!, owner.language),
          unsure: false,
        };
      }
    }
    // Doubtful spam stays in the inbox, untouched, until the person decides.
    const doubt = decision.action.kind === 'spam' && decision.unsure;
    const ops = doubt ? [] : serverOpsFor(decision.action);
    if (ops.length) await mail.apply(message.id, ops);

    db.transaction((tx) => {
      tx.insert(triageLog)
        .values({
          messageId: message.id,
          personId: box.ownerId,
          bot: bot.name,
          action: decision.action,
          reason: decision.reason,
          unsure: decision.unsure,
          ops,
          status: doubt ? 'doubt' : statusFor(decision.action),
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
    return this.list(access, 'pending-review');
  }

  // Inbox mail the bot thought might be spam, waiting for the person.
  listDoubts(access: Access): FilteredEntry[] {
    return this.list(access, 'doubt');
  }

  private list(access: Access, status: TriageStatus): FilteredEntry[] {
    if (!access.mailboxIds.length) return [];
    const rows = this.o.platform.db
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
          eq(triageLog.status, status),
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
      message: forKey(toSummary(message), access),
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
    await this.o.mail.apply(
      entry.message.id,
      restoreOps(entry.log.action, entry.log.ops),
    );
    this.setStatus(entry.log.id, 'restored');
    const sender = entry.message.from.email.toLowerCase();
    if (entry.log.action.kind === 'spam') {
      this.learn(entry.log.personId, 'not-spam', sender, 'address');
      return;
    }
    const text = `Keep mail from ${sender} in the inbox (it was filtered as ${entry.log.action.kind} and restored).`;
    if (!this.rules(entry.log.personId).some((r) => r.text === text))
      this.o.platform.db
        .insert(learnedRules)
        .values({ personId: entry.log.personId, text })
        .run();
  }

  // The person's answer to a doubt: spam moves it and teaches the sender,
  // not spam leaves the mail as it is and teaches the opposite.
  async settleDoubt(
    entryId: string,
    verdict: RuleKind,
    access: Access,
  ): Promise<void> {
    const entry = this.reviewable(entryId, access, 'doubt');
    if (!entry) throw new TriageError('not found');
    const { message, log } = entry;
    if (verdict === 'not-spam') {
      this.setStatus(log.id, 'restored');
      this.learn(log.personId, 'not-spam', message.from.email, 'address');
      return;
    }
    const ops = serverOpsFor({ kind: 'spam' });
    await this.o.mail.apply(message.id, ops);
    this.o.platform.db
      .update(triageLog)
      .set({ ops, status: 'confirmed', reviewedAt: new Date() })
      .where(eq(triageLog.id, log.id))
      .run();
    this.learn(log.personId, 'spam', ...ruleTarget(message));
  }

  // After the person moved a message into or out of spam themselves
  // ("Markeer als spam", or back to the inbox): settles what triage left open
  // for it, logs the correction and learns the sender. Only the mailbox
  // owner teaches, as the rules are theirs.
  learnFromHand(before: MessageRow, ops: ServerOp[], access: Access): void {
    const box = this.o.mail.mailbox(before.mailboxId);
    if (!box || box.ownerId !== access.personId) return;
    const toSpam =
      before.folder !== 'spam' && ops.some((o) => o.op === 'moveToSpam');
    const outOfSpam =
      before.folder === 'spam' && ops.some((o) => o.op === 'moveToInbox');
    if (!toSpam && !outOfSpam) return;
    const db = this.o.platform.db;
    const open = db
      .select({ id: triageLog.id })
      .from(triageLog)
      .where(
        and(
          eq(triageLog.messageId, before.id),
          inArray(triageLog.status, ['doubt', 'pending-review']),
        ),
      )
      .all();
    for (const entry of open)
      this.setStatus(entry.id, toSpam ? 'confirmed' : 'restored');
    db.insert(triageLog)
      .values({
        messageId: before.id,
        personId: box.ownerId,
        bot: 'hand',
        action: { kind: toSpam ? 'spam' : 'keep' },
        reason: toSpam
          ? 'Marked as spam by hand.'
          : 'Moved out of spam by hand.',
        unsure: false,
        ops: ops.filter((o) => ['moveToSpam', 'moveToInbox'].includes(o.op)),
        status: toSpam ? 'confirmed' : 'restored',
      })
      .run();
    if (toSpam) this.learn(box.ownerId, 'spam', ...ruleTarget(before));
    else this.learn(box.ownerId, 'not-spam', before.from.email, 'address');
  }

  rules(personId: string) {
    return this.o.platform.db
      .select()
      .from(learnedRules)
      .where(eq(learnedRules.personId, personId))
      .orderBy(learnedRules.createdAt)
      .all();
  }

  deleteRule(personId: string, id: string): boolean {
    const gone = this.o.platform.db
      .delete(learnedRules)
      .where(and(eq(learnedRules.id, id), eq(learnedRules.personId, personId)))
      .returning()
      .all();
    return gone.length > 0;
  }

  // The latest correction about a sender replaces any earlier one.
  private learn(
    personId: string,
    kind: RuleKind,
    sender: string,
    scope: RuleScope,
  ) {
    const db = this.o.platform.db;
    const who = sender.toLowerCase();
    db.delete(learnedRules)
      .where(
        and(eq(learnedRules.personId, personId), eq(learnedRules.sender, who)),
      )
      .run();
    const from = scope === 'domain' ? `any address at ${who}` : who;
    const text =
      kind === 'spam'
        ? `Mail from ${from} is spam: the person marked it as spam.`
        : `Keep mail from ${from} in the inbox: the person said it is not spam.`;
    db.insert(learnedRules).values({ personId, text, kind, sender: who }).run();
  }

  // A rule for the address wins over one for its domain.
  private senderRule(personId: string, email: string) {
    const address = email.toLowerCase();
    const domain = address.slice(address.lastIndexOf('@') + 1);
    const found = this.o.platform.db
      .select()
      .from(learnedRules)
      .where(
        and(
          eq(learnedRules.personId, personId),
          inArray(learnedRules.sender, [address, domain]),
        ),
      )
      .all();
    return found.find((r) => r.sender === address) ?? found[0];
  }

  private reviewable(
    id: string,
    access: Access,
    status: TriageStatus = 'pending-review',
  ) {
    const row = this.o.platform.db
      .select({ log: triageLog, message: messages })
      .from(triageLog)
      .innerJoin(messages, eq(messages.id, triageLog.messageId))
      .where(eq(triageLog.id, id))
      .get();
    if (!row || row.log.status !== status) return undefined;
    if (!access.mailboxIds.includes(row.message.mailboxId)) return undefined;
    return row;
  }

  private setStatus(id: string, status: TriageStatus) {
    this.o.platform.db
      .update(triageLog)
      .set({ status, reviewedAt: new Date() })
      .where(eq(triageLog.id, id))
      .run();
  }

  private ownerWroteTo(personId: string, email: string): boolean {
    const needle = `%"email":${JSON.stringify(email)}%`;
    const hit = this.o.platform.db
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
