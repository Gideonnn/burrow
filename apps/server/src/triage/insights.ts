import { type MessageInsights, messageInsights } from '@burrow/contracts';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import type { AgentRunner } from '../agents/runner';
import type { Catalog } from '../catalog/loadCatalog';
import type { Db } from '../db/client';
import {
  instructions,
  messageInsights as insightsTable,
  people,
} from '../db/schema';
import type { MailService } from '../mail/service';
import { systemPrompt, triagePrompt } from './prompt';

const SKILL = 'reply-suggestions';
const schema = z.toJSONSchema(messageInsights, { target: 'draft-7' });
// Long enough that a summary saves reading time.
export const LONG_MESSAGE = 1_500;

export type InsightsOptions = {
  db: Db;
  mail: MailService;
  runner: AgentRunner;
  catalog: Catalog;
  bot: string;
  language?: string;
};

// Summaries and reply suggestions, generated once per message and cached.
// Concurrent requests for the same message share one agent run.
export class InsightsService {
  private readonly running = new Map<string, Promise<MessageInsights>>();

  constructor(private readonly o: InsightsOptions) {
    const bot = o.catalog.bots.get(o.bot);
    if (!bot?.skills.includes(SKILL) || !o.catalog.skills.has(SKILL)) {
      throw new Error(
        `bot "${o.bot}" needs the ${SKILL} skill for reply suggestions`,
      );
    }
  }

  cached(messageId: string): MessageInsights | undefined {
    const row = this.o.db
      .select()
      .from(insightsTable)
      .where(eq(insightsTable.messageId, messageId))
      .get();
    return row ? { summary: row.summary, replies: row.replies } : undefined;
  }

  get(messageId: string): Promise<MessageInsights> {
    const hit = this.cached(messageId);
    if (hit) return Promise.resolve(hit);
    let run = this.running.get(messageId);
    if (!run) {
      run = this.generate(messageId).finally(() =>
        this.running.delete(messageId),
      );
      this.running.set(messageId, run);
    }
    return run;
  }

  // Warms the cache in the background, e.g. right after triage flagged a
  // message as needing a reply, so the client shows suggestions at once.
  prefetch(messageId: string) {
    this.get(messageId).catch((error: Error) =>
      console.error(`insights for ${messageId} failed: ${error.message}`),
    );
  }

  private async generate(messageId: string): Promise<MessageInsights> {
    const { db, mail, runner, catalog } = this.o;
    const message = mail.message(messageId);
    if (!message) throw new Error('unknown message');
    const box = mail.mailbox(message.mailboxId)!;
    const owner = db
      .select()
      .from(people)
      .where(eq(people.id, box.ownerId))
      .get()!;
    const bot = catalog.bots.get(this.o.bot)!;
    const raw = await runner.run({
      model: bot.model,
      system: systemPrompt(bot, [catalog.skills.get(SKILL)!]),
      prompt: triagePrompt({
        ownerName: owner.name,
        instructions:
          db
            .select()
            .from(instructions)
            .where(eq(instructions.personId, owner.id))
            .get()?.text ?? '',
        mailboxInstructions: box.instructions,
        rules: [],
        mailbox: { address: box.address, provider: box.provider },
        message,
        ownerWroteToSender: false,
        language: owner.language ?? this.o.language ?? 'English',
        task: 'Write a summary (when the message is long) and reply suggestions for',
      }),
      schema,
    });
    const insights = messageInsights.parse(raw);
    db.insert(insightsTable)
      .values({
        messageId,
        bot: bot.name,
        summary: insights.summary,
        replies: insights.replies,
      })
      .onConflictDoNothing()
      .run();
    return insights;
  }
}
