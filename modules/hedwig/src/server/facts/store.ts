import type { MessageFacts, MessageSummary } from '@burrow/contracts';
import type { Access, Db } from '@burrow/platform';
import { inArray } from 'drizzle-orm';
import { type MessageRow, toSummary } from '../mail-service';
import { messageFacts } from '../schema';

export type FactsRow = typeof messageFacts.$inferSelect;

export function toFacts(f: FactsRow): MessageFacts {
  return {
    category: f.category ?? null,
    priority: f.priority ?? null,
    summary: f.summary ?? null,
    sensitive: f.sensitive,
    sensitiveKinds: f.sensitiveKinds,
    people: f.people,
    organisations: f.organisations,
    amounts: f.amounts,
    dates: f.dates,
    keywords: f.keywords,
    source: f.source,
  };
}

export function factsFor(
  db: Db,
  messageIds: readonly string[],
): Map<string, MessageFacts> {
  const found = new Map<string, MessageFacts>();
  for (let i = 0; i < messageIds.length; i += 500) {
    for (const f of db
      .select()
      .from(messageFacts)
      .where(inArray(messageFacts.messageId, messageIds.slice(i, i + 500)))
      .all()) {
      found.set(f.messageId, toFacts(f));
    }
  }
  return found;
}

// Summaries with their facts; a facts-only key gets no snippet.
export function summaries(
  db: Db,
  rows: readonly MessageRow[],
  access?: Pick<Access, 'factsOnly'>,
): MessageSummary[] {
  const facts = factsFor(
    db,
    rows.map((r) => r.id),
  );
  return rows.map((row) => {
    const summary = toSummary(row, facts.get(row.id) ?? null);
    return access?.factsOnly ? { ...summary, snippet: '' } : summary;
  });
}
