import {
  type MailFolder,
  type MailboxRole,
  type MessageSummary,
  type SearchPlan,
  type SearchResponse,
  type SearchScope,
  searchPlan,
} from '@burrow/contracts';
import { type Db, type Platform, systemPrompt } from '@burrow/platform';
import {
  and,
  type Column,
  desc,
  eq,
  gte,
  inArray,
  lt,
  or,
  sql,
} from 'drizzle-orm';
import { z } from 'zod';
import { type MessageRow, toSummary } from './mail-service';
import { mailboxes, messages } from './schema';

const SKILL = 'mail-search';
const schema = z.toJSONSchema(searchPlan, { target: 'draft-7' });
const CANDIDATES = 500;

export type SearchQuery = {
  // Every group must match for word search; for a plan, any group does and
  // more matching groups rank higher.
  groups: string[][];
  matchAll: boolean;
  from?: string | null;
  after?: string | null;
  before?: string | null;
  folder?: MailFolder | null;
  roles?: MailboxRole[] | null;
  unreadOnly?: boolean;
  hasAttachments?: boolean;
  limit: number;
};

// LIKE wildcards in what someone typed are taken literally.
const pattern = (word: string) =>
  `%${word.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
const likeEscaped = (column: Column, word: string) =>
  sql`${column} like ${pattern(word)} escape '\\'`;

const anyField = (word: string) =>
  or(
    likeEscaped(messages.subject, word),
    likeEscaped(messages.from, word),
    likeEscaped(messages.to, word),
    likeEscaped(messages.bodyText, word),
  );

const contains = (haystack: string, word: string) =>
  haystack.toLowerCase().includes(word.toLowerCase());

// Searches the mail on the server, newest first; with a plan, messages that
// match more of its groups (and in the subject) come first.
export function searchMessages(
  db: Db,
  mailboxIds: readonly string[],
  query: SearchQuery,
): MessageSummary[] {
  let scope = [...mailboxIds];
  if (query.roles?.length && scope.length) {
    scope = db
      .select({ id: mailboxes.id })
      .from(mailboxes)
      .where(
        and(inArray(mailboxes.id, scope), inArray(mailboxes.role, query.roles)),
      )
      .all()
      .map((r) => r.id);
  }
  if (!scope.length) return [];
  const groups = query.groups.filter((g) => g.length);
  const groupSql = groups.map((g) => or(...g.map(anyField)));
  const rows = db
    .select()
    .from(messages)
    .where(
      and(
        inArray(messages.mailboxId, scope),
        query.folder ? eq(messages.folder, query.folder) : undefined,
        query.unreadOnly ? eq(messages.unread, true) : undefined,
        query.hasAttachments ? eq(messages.hasAttachments, true) : undefined,
        query.from ? likeEscaped(messages.from, query.from) : undefined,
        query.after
          ? gte(messages.receivedAt, new Date(query.after))
          : undefined,
        query.before
          ? lt(messages.receivedAt, new Date(query.before))
          : undefined,
        groupSql.length
          ? query.matchAll
            ? and(...groupSql)
            : or(...groupSql)
          : undefined,
      ),
    )
    .orderBy(desc(messages.receivedAt))
    .limit(query.matchAll ? query.limit : CANDIDATES)
    .all();
  if (query.matchAll) return rows.map(toSummary);
  return rows
    .map((row, index) => ({ row, index, score: score(row, groups) }))
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, query.limit)
    .map(({ row }) => toSummary(row));
}

function score(row: MessageRow, groups: string[][]) {
  const text = [
    row.from.name ?? '',
    row.from.email,
    ...row.to.map((a) => `${a.name ?? ''} ${a.email}`),
    row.bodyText ?? '',
  ].join(' ');
  let total = 0;
  for (const group of groups) {
    if (group.some((w) => contains(row.subject, w))) total += 2;
    else if (group.some((w) => contains(text, w))) total += 1;
  }
  return total;
}

// The place the person has open wins over the bot's plan.
export function inScope(query: SearchQuery, scope: SearchScope): SearchQuery {
  return {
    ...query,
    folder: scope.folder ?? query.folder,
    roles: scope.role ? [scope.role] : scope.mailboxId ? null : query.roles,
  };
}

// Splits typed words; quotes keep a phrase together.
export function words(q: string): string[][] {
  return [...q.matchAll(/"([^"]+)"|(\S+)/g)]
    .map((m) => (m[1] ?? m[2] ?? '').trim())
    .filter(Boolean)
    .map((w) => [w]);
}

export type SearchOptions = { platform: Platform; bot: string };

// Search by meaning: the bot turns the question into words and filters; the
// server runs that search over the key's mailboxes. Only the question reaches
// the bot, never the mail, so a message cannot steer the search.
export class SearchService {
  constructor(private readonly o: SearchOptions) {}

  get available(): boolean {
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot);
    return Boolean(bot?.skills.includes(SKILL) && catalog.skills.has(SKILL));
  }

  async ask(
    personId: string,
    mailboxIds: readonly string[],
    question: string,
    scope: SearchScope = {},
  ): Promise<SearchResponse> {
    const { platform } = this.o;
    const { catalog, runner, db } = platform;
    const bot = catalog.bots.get(this.o.bot)!;
    const person = platform.owner(personId);
    const boxes = mailboxIds.length
      ? db
          .select({
            address: mailboxes.address,
            name: mailboxes.name,
            role: mailboxes.role,
          })
          .from(mailboxes)
          .where(
            and(
              inArray(mailboxes.id, [...mailboxIds]),
              scope.role ? eq(mailboxes.role, scope.role) : undefined,
            ),
          )
          .all()
      : [];
    const raw = await runner.run({
      model: bot.model,
      agent: bot.agent,
      system: systemPrompt(bot, [catalog.skills.get(SKILL)!]),
      prompt: [
        `Today is ${new Date().toISOString().slice(0, 10)}.`,
        `${person.name} searches their mail${person.language ? ` and writes in ${person.language}` : ''}.`,
        `Their mailboxes: ${boxes.map((b) => `${b.address} (${b.role}${b.name ? `, "${b.name}"` : ''})`).join('; ') || 'none'}.`,
        '',
        'Their question:',
        question,
      ].join('\n'),
      schema,
    });
    const plan: SearchPlan = searchPlan.parse(raw);
    return {
      explanation: plan.explanation,
      results: searchMessages(
        db,
        mailboxIds,
        inScope({ ...plan, matchAll: false, limit: 50 }, scope),
      ),
    };
  }
}
