import type {
  FactCategory,
  MailFolder,
  MailboxRole,
  SearchFilters,
  SearchResult,
  SearchScope,
} from '@burrow/contracts';
import type { Db } from '@burrow/platform';
import {
  and,
  eq,
  getTableColumns,
  gte,
  inArray,
  isNull,
  lt,
  notInArray,
  or,
  type SQL,
  sql,
} from 'drizzle-orm';
import { type FactsRow, forKey, toFacts } from './facts/store';
import { type MessageRow, toSummary } from './mail-service';
import { findPeople } from './people';
import { mailboxes, messageFacts, messages } from './schema';
import { ftsPhrase, hitIn, parseQuery, tokens } from './search-text';

const NOISE: FactCategory[] = ['code', 'account'];
// Subject, people, body, facts: a word in the subject says most.
const BM25 = sql.raw('bm25(message_search, 10.0, 4.0, 1.0, 3.0)');
const CANDIDATES = 400;

export type SearchQuery = {
  // Every group must match for word search; for a plan, any group does and
  // more matching groups rank higher.
  groups: string[][];
  matchAll: boolean;
  // While typing, the last word may be the start of a longer one.
  typing?: boolean;
  excluded?: string[];
  // Addresses, or "@domain", in From, To or Cc.
  people?: string[];
  from?: string | null;
  after?: string | null;
  before?: string | null;
  folder?: MailFolder | null;
  roles?: MailboxRole[] | null;
  unreadOnly?: boolean;
  hasAttachments?: boolean;
  categories?: FactCategory[] | null;
  // Login codes and account notices are left out unless asked for.
  includeLow?: boolean;
  // A facts-only key searches subjects, people and facts, never bodies.
  factsOnly?: boolean;
  // Messages to search beyond the mailboxes, such as mail shared with the person.
  alsoIds?: readonly string[];
  // Only these messages, such as the nearest by meaning.
  onlyIds?: readonly string[];
  // With nothing to match on, list the newest mail instead of none.
  browse?: boolean;
  limit: number;
};

export type SearchOutcome = { results: SearchResult[]; total: number };

const phrase = (word: string, prefix: boolean) =>
  ftsPhrase(word, prefix && tokens(word).at(-1)!.length >= 3);

// The FTS5 expression for the words and people; null when there is nothing
// to match on and the filters alone decide.
export function ftsExpression(query: SearchQuery): string | null {
  const groups = query.groups
    .map((group, gi) => {
      const last = gi === query.groups.length - 1;
      const parts = group
        .map((w, wi) => {
          // The word being typed matches from two letters on; others from three.
          if (query.typing && last && wi === group.length - 1) {
            const t = tokens(w);
            if (t.length === 1 && t[0]!.length < 2) return null;
            return ftsPhrase(w, true);
          }
          return phrase(w, !w.includes(' '));
        })
        .filter((p): p is string => p !== null);
      return parts.length
        ? parts.length > 1
          ? `(${parts.join(' OR ')})`
          : parts[0]!
        : null;
    })
    .filter((g): g is string => g !== null);
  let words = groups.length
    ? groups.join(query.matchAll ? ' AND ' : ' OR ')
    : null;
  if (words && query.factsOnly) words = `{subject people facts} : (${words})`;
  const people = (query.people ?? [])
    .map((p) => ftsPhrase(p.replace(/^@/, ''), false))
    .filter((p): p is string => p !== null);
  const who = people.length ? `{people} : (${people.join(' OR ')})` : null;
  let expr =
    [words && (who ? `(${words})` : words), who]
      .filter(Boolean)
      .join(' AND ') || null;
  const excluded = (query.excluded ?? [])
    .map((w) => ftsPhrase(w, false))
    .filter((p): p is string => p !== null);
  if (expr && excluded.length)
    expr = `(${expr}) NOT (${excluded.join(' OR ')})`;
  return expr;
}

// The folded words a result is marked with.
const highlightTerms = (query: Pick<SearchQuery, 'groups'>) =>
  [...new Set(query.groups.flat().flatMap((w) => tokens(w)))].filter(
    (t) => t.length >= 2,
  );

function scopeOf(
  db: Db,
  mailboxIds: readonly string[],
  roles?: MailboxRole[] | null,
) {
  let scope = [...mailboxIds];
  if (roles?.length && scope.length) {
    scope = db
      .select({ id: mailboxes.id })
      .from(mailboxes)
      .where(and(inArray(mailboxes.id, scope), inArray(mailboxes.role, roles)))
      .all()
      .map((r) => r.id);
  }
  return scope;
}

function filters(query: SearchQuery, scope: string[]): SQL | undefined {
  const also = query.alsoIds?.length
    ? inArray(messages.id, [...query.alsoIds])
    : undefined;
  return and(
    scope.length && also
      ? or(inArray(messages.mailboxId, scope), also)
      : scope.length
        ? inArray(messages.mailboxId, scope)
        : also,
    query.onlyIds ? inArray(messages.id, [...query.onlyIds]) : undefined,
    query.includeLow
      ? undefined
      : or(
          isNull(messageFacts.category),
          notInArray(messageFacts.category, NOISE),
        ),
    query.categories?.length
      ? inArray(messageFacts.category, query.categories)
      : undefined,
    query.folder ? eq(messages.folder, query.folder) : undefined,
    query.unreadOnly ? eq(messages.unread, true) : undefined,
    query.hasAttachments ? eq(messages.hasAttachments, true) : undefined,
    query.from
      ? sql`lower(${messages.from}) like ${`%${query.from.toLowerCase().replace(/[\\%_]/g, (c) => `\\${c}`)}%`} escape '\\'`
      : undefined,
    query.after ? gte(messages.receivedAt, new Date(query.after)) : undefined,
    query.before ? lt(messages.receivedAt, new Date(query.before)) : undefined,
  );
}

// Relevance from the index, a little in favour of recent mail: a year-old
// message weighs three quarters of a new one with the same words.
const blended = (rank: number, at: number, now: number) =>
  -rank * (0.75 + 0.25 * 0.5 ** (Math.max(0, now - at) / 86_400_000 / 365));

// Searches the mail on the server through the full-text index. With words,
// the best matches come first; with only filters (a person, a period), the
// newest.
export function searchMessages(
  db: Db,
  mailboxIds: readonly string[],
  query: SearchQuery,
  now = Date.now(),
): SearchOutcome {
  const scope = scopeOf(db, mailboxIds, query.roles);
  if (!scope.length && !query.alsoIds?.length) return { results: [], total: 0 };
  const expr = ftsExpression(query);
  const hasWords = query.groups.some((g) => g.length);
  // Words typed but none long enough yet: nothing to show.
  if (hasWords && !expr) return { results: [], total: 0 };
  if (
    !expr &&
    !query.people?.length &&
    !query.from &&
    !query.after &&
    !query.before &&
    !query.categories?.length &&
    !query.hasAttachments &&
    !query.unreadOnly &&
    !query.onlyIds &&
    !query.browse
  ) {
    return { results: [], total: 0 };
  }
  const where = filters(query, scope);
  let ranked: { id: string; score: number }[];
  let total: number;
  if (expr) {
    const rows = db.all<{ id: string; rank: number; at: number }>(sql`
      select messages.id as id, ${BM25} as rank, messages.received_at as at
      from message_search
      join message_search_keys k on k.id = message_search.rowid
      join messages on messages.id = k.message_id
      left join message_facts on message_facts.message_id = messages.id
      where message_search match ${expr} ${where ? sql`and ${where}` : sql``}
      order by ${hasWords ? sql`rank` : sql`messages.received_at desc`}
      limit ${Math.max(CANDIDATES, query.limit * 3)}`);
    total = rows.length;
    if (rows.length >= Math.max(CANDIDATES, query.limit * 3)) {
      total = db.get<{ n: number }>(sql`
        select count(*) as n from message_search
        join message_search_keys k on k.id = message_search.rowid
        join messages on messages.id = k.message_id
        left join message_facts on message_facts.message_id = messages.id
        where message_search match ${expr} ${where ? sql`and ${where}` : sql``}`)!.n;
    }
    ranked = rows.map((r) => ({
      id: r.id,
      score: hasWords ? blended(r.rank, r.at, now) : r.at,
    }));
    ranked.sort((a, b) => b.score - a.score);
  } else {
    const rows = db
      .select({ id: messages.id })
      .from(messages)
      .leftJoin(messageFacts, eq(messageFacts.messageId, messages.id))
      .where(where)
      .orderBy(sql`${messages.receivedAt} desc`)
      .limit(query.limit)
      .all();
    total =
      rows.length < query.limit
        ? rows.length
        : db.get<{ n: number }>(
            sql`select count(*) as n from messages left join message_facts on message_facts.message_id = messages.id where ${where}`,
          )!.n;
    ranked = rows.map((r, i) => ({ id: r.id, score: -i }));
  }
  const ids = ranked.slice(0, query.limit).map((r) => r.id);
  return { results: load(db, ids, query), total };
}

// The messages in the given order, each with the piece where it matched.
export function load(
  db: Db,
  ids: readonly string[],
  query: Pick<SearchQuery, 'groups' | 'factsOnly'>,
): SearchResult[] {
  if (!ids.length) return [];
  const rows = new Map<string, { m: MessageRow; f: FactsRow | null }>();
  for (let i = 0; i < ids.length; i += 500) {
    for (const row of db
      .select({ m: getTableColumns(messages), f: messageFacts })
      .from(messages)
      .leftJoin(messageFacts, eq(messageFacts.messageId, messages.id))
      .where(inArray(messages.id, ids.slice(i, i + 500)))
      .all()) {
      rows.set(row.m.id, row);
    }
  }
  const terms = highlightTerms(query);
  return ids.flatMap((id) => {
    const row = rows.get(id);
    if (!row) return [];
    const summary = forKey(
      toSummary(row.m, row.f ? toFacts(row.f) : null),
      query,
    );
    const hit = query.factsOnly
      ? hitIn('facts', row.f?.summary ?? '', terms)
      : (hitIn('body', row.m.bodyText ?? '', terms) ??
        hitIn('facts', row.f?.summary ?? '', terms));
    return [{ ...summary, hit }];
  });
}

// The place the person has open wins over the bot's plan.
export function inScope<Q extends Pick<SearchQuery, 'folder' | 'roles'>>(
  query: Q,
  scope: SearchScope,
): Q {
  return {
    ...query,
    folder: scope.folder ?? query.folder,
    roles: scope.role ? [scope.role] : scope.mailboxId ? null : query.roles,
  };
}

// What someone typed in the search field as a query: every word must match,
// "quotes" keep a phrase, -word leaves out, @name is a person they mail with.
export function typedQuery(
  db: Db,
  mailboxIds: readonly string[],
  q: string,
  filters: Partial<SearchFilters> = {},
): Omit<SearchQuery, 'limit'> {
  const parsed = parseQuery(q);
  const people = [...(filters.people ?? [])];
  for (const mention of parsed.mentions) {
    if (mention.includes('@')) {
      people.push(mention);
      continue;
    }
    const best = findPeople(db, mailboxIds, mention, 1)[0];
    // Nobody by that name: any address or name that starts with it.
    people.push(...(best ? best.emails : [mention]));
  }
  return {
    // Phrases first, so the word being typed is the last group.
    groups: [
      ...parsed.phrases.map((p) => [p]),
      ...parsed.words.map((w) => [w]),
    ],
    matchAll: true,
    typing:
      !q.endsWith(' ') &&
      !q.endsWith('"') &&
      parsed.words.length > 0 &&
      q.trim().endsWith(parsed.words.at(-1)!),
    excluded: parsed.excluded,
    people,
    after: filters.after ?? null,
    before: filters.before ?? null,
    categories: filters.categories ?? null,
    hasAttachments: filters.hasAttachments ?? false,
    unreadOnly: filters.unreadOnly ?? false,
  };
}

// Splits typed words; quotes keep a phrase together.
export function words(q: string): string[][] {
  const parsed = parseQuery(q);
  return [...parsed.words, ...parsed.phrases].map((w) => [w]);
}
