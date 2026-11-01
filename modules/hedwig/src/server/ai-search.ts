import {
  type FactCategory,
  type RankResponse,
  type SearchFilters,
  type SearchPlan,
  type SearchResponse,
  type SearchResult,
  type SearchScope,
  type SearchToken,
  searchPlan,
} from '@burrow/contracts';
import { botRequest, type Platform, untrusted } from '@burrow/platform';
import { and, eq, inArray } from 'drizzle-orm';
import { z } from 'zod';
import { redact } from './facts/rules';
import { findPeople } from './people';
import { mailboxes } from './schema';
import { inScope, load, matchingIds, type SearchQuery } from './search';
import type { VectorIndex } from './vectors';

const PLAN_SKILL = 'mail-search';
const RANK_SKILL = 'mail-search-rank';
export const SEARCH_ABOUT = 'hedwig.searchAbout';
export const SEARCH_READS = 'hedwig.searchReads';
const planSchema = z.toJSONSchema(searchPlan, { target: 'draft-7' });
const ranking = z.object({
  relevant: z.array(z.number().int()).max(30),
  answer: z.string().max(400).nullable(),
  answerFrom: z.array(z.number().int()).max(5),
});
const rankSchema = z.toJSONSchema(ranking, { target: 'draft-7' });
// Reciprocal rank fusion: a message high in any list rises; one in several
// rises most. 60 is the usual constant.
const RRF = 60;

const CATEGORY_LABELS: Partial<Record<FactCategory, string>> = {
  personal: 'Persoonlijk',
  work: 'Werk',
  school: 'School',
  order: 'Bestellingen',
  shipping: 'Pakketten',
  invoice: 'Facturen',
  bank: 'Bank',
  travel: 'Reizen',
  appointment: 'Afspraken',
  government: 'Overheid',
  health: 'Gezondheid',
  newsletter: 'Nieuwsbrieven',
  promotion: 'Aanbiedingen',
  notification: 'Meldingen',
  account: 'Accounts',
  code: 'Codes',
};

const MONTHS = [
  'jan',
  'feb',
  'mrt',
  'apr',
  'mei',
  'jun',
  'jul',
  'aug',
  'sep',
  'okt',
  'nov',
  'dec',
];
const FULL_MONTHS = [
  'januari',
  'februari',
  'maart',
  'april',
  'mei',
  'juni',
  'juli',
  'augustus',
  'september',
  'oktober',
  'november',
  'december',
];

// "maart 2026", "2025", "1 mrt – 15 apr 2026", "na 1 mrt 2026".
export function periodLabel(
  after: string | null,
  before: string | null,
): string {
  const d = (s: string) => new Date(`${s}T00:00:00Z`);
  const day = (s: string) =>
    `${d(s).getUTCDate()} ${MONTHS[d(s).getUTCMonth()]} ${d(s).getUTCFullYear()}`;
  if (after && before) {
    const a = d(after);
    const b = d(before);
    const last = new Date(b.getTime() - 86_400_000);
    if (a.getUTCDate() === 1 && b.getUTCDate() === 1) {
      const months =
        (b.getUTCFullYear() - a.getUTCFullYear()) * 12 +
        b.getUTCMonth() -
        a.getUTCMonth();
      if (months === 1)
        return `${FULL_MONTHS[a.getUTCMonth()]} ${a.getUTCFullYear()}`;
      if (months === 12 && a.getUTCMonth() === 0)
        return `${a.getUTCFullYear()}`;
    }
    return `${day(after)} – ${day(last.toISOString().slice(0, 10))}`;
  }
  if (after) return `na ${day(after)}`;
  if (before) return `voor ${day(before)}`;
  return '';
}

function fuse(lists: { ids: string[]; weight: number }[]): string[] {
  const score = new Map<string, number>();
  for (const { ids, weight } of lists) {
    ids.forEach((id, i) =>
      score.set(id, (score.get(id) ?? 0) + weight / (RRF + i + 1)),
    );
  }
  return [...score.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id);
}

export type AskOptions = {
  includeLow?: boolean;
  factsOnly?: boolean;
  filters?: SearchFilters;
  vector?: { model: string; values: number[] };
  alsoIds?: readonly string[];
  plan?: SearchPlan;
  without?: string[];
};

export type SearchServiceOptions = {
  platform: Platform;
  bot: string;
  vectors: VectorIndex;
};

// Search by meaning in two steps. Ask: the bot turns the question into a plan
// (words, people, a period, kinds) without seeing any mail; the server runs it
// three ways (every group, any group, nearest by meaning) and fuses the lists.
// Rank: when the person allows it, the bot reads subject and summary of the
// best thirty, which are untrusted, and orders them and answers; it has no
// tools, so a crafted mail can at most mislead the order or the sentence.
export class SearchService {
  constructor(private readonly o: SearchServiceOptions) {}

  private has(skill: string) {
    const { catalog } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot);
    return Boolean(bot?.skills.includes(skill) && catalog.skills.has(skill));
  }

  get available(): boolean {
    return this.has(PLAN_SKILL);
  }

  canRank(personId: string): boolean {
    return (
      this.has(RANK_SKILL) &&
      this.o.platform.settings.enabled(personId, SEARCH_READS)
    );
  }

  private about(personId: string) {
    const { platform } = this.o;
    const person = platform.owner(personId);
    const about = String(
      platform.settings.get(personId, SEARCH_ABOUT) ?? '',
    ).trim();
    return [
      `Today is ${new Date().toISOString().slice(0, 10)}.`,
      `${person.name} searches their mail${person.language ? ` and writes in ${person.language}` : ''}.`,
      ...(about ? [`What ${person.name} says about themselves: ${about}`] : []),
    ];
  }

  async plan(
    personId: string,
    mailboxIds: readonly string[],
    question: string,
    scope: SearchScope,
    filters?: SearchFilters,
  ): Promise<SearchPlan> {
    const { catalog, runner, db } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot)!;
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
    const given = [
      ...(filters?.people.length
        ? [`people ${filters.people.join(', ')}`]
        : []),
      ...(filters?.after || filters?.before
        ? [`period ${periodLabel(filters.after, filters.before)}`]
        : []),
      ...(filters?.categories?.length
        ? [`kinds ${filters.categories.join(', ')}`]
        : []),
    ];
    const raw = await runner.run({
      ...botRequest(bot, [catalog.skills.get(PLAN_SKILL)!]),
      prompt: [
        ...this.about(personId),
        `Their mailboxes: ${boxes.map((b) => `${b.address} (${b.role}${b.name ? `, "${b.name}"` : ''})`).join('; ') || 'none'}.`,
        ...(given.length
          ? [
              `Already chosen in the search field, leave these out of the plan: ${given.join('; ')}.`,
            ]
          : []),
        '',
        'Their question:',
        question,
      ].join('\n'),
      schema: planSchema,
    });
    return searchPlan.parse(raw);
  }

  async ask(
    personId: string,
    mailboxIds: readonly string[],
    question: string,
    scope: SearchScope = {},
    options: AskOptions = {},
  ): Promise<SearchResponse> {
    const plan =
      options.plan ??
      (await this.plan(personId, mailboxIds, question, scope, options.filters));
    return this.run(plan, mailboxIds, scope, options);
  }

  // Runs a plan: what ask does after the bot answered. Parts named in
  // `without` are left out, so a person can drop a token without a new plan.
  run(
    original: SearchPlan,
    mailboxIds: readonly string[],
    scope: SearchScope,
    options: AskOptions = {},
  ): SearchResponse {
    const { db } = this.o.platform;
    const without = new Set(options.without ?? []);
    const plan: SearchPlan = {
      ...original,
      groups: original.groups.filter((_, i) => !without.has(`group:${i}`)),
      people: original.people.filter((_, i) => !without.has(`people:${i}`)),
      after: without.has('period') ? null : original.after,
      before: without.has('period') ? null : original.before,
      categories:
        original.categories?.filter((c) => !without.has(`category:${c}`)) ??
        null,
      hasAttachments: original.hasAttachments && !without.has('attachments'),
      unreadOnly: original.unreadOnly && !without.has('unread'),
    };
    // Keys point into the original plan, so a second removal still matches.
    const groupKey = (g: string[]) => `group:${original.groups.indexOf(g)}`;
    const tokens: SearchToken[] = [];
    const groups: { key: string; words: string[] }[] = plan.groups.map((g) => ({
      key: groupKey(g),
      words: [...g],
    }));
    const people = [...(options.filters?.people ?? [])];
    plan.people.forEach((name) => {
      const key = `people:${original.people.indexOf(name)}`;
      const person = findPeople(db, mailboxIds, name, 1)[0];
      if (person) {
        people.push(...person.emails);
        tokens.push({
          key,
          kind: 'person',
          label: person.name,
          emails: person.emails,
        });
      } else {
        // Not someone they mail with: maybe the name is in the mail itself.
        groups.unshift({ key, words: [name] });
      }
    });
    const filters = options.filters;
    const after = filters?.after ?? plan.after;
    const before = filters?.before ?? plan.before;
    const categories = filters?.categories?.length
      ? filters.categories
      : plan.categories;
    if ((plan.after || plan.before) && !filters?.after && !filters?.before) {
      tokens.push({
        key: 'period',
        kind: 'period',
        label: periodLabel(plan.after, plan.before),
        after: plan.after,
        before: plan.before,
      });
    }
    for (const category of filters?.categories?.length
      ? []
      : (plan.categories ?? [])) {
      tokens.push({
        key: `category:${category}`,
        kind: 'category',
        label: CATEGORY_LABELS[category] ?? category,
        category,
      });
    }
    if (plan.hasAttachments)
      tokens.push({
        key: 'attachments',
        kind: 'attachments',
        label: 'Met bijlage',
      });
    if (plan.unreadOnly)
      tokens.push({ key: 'unread', kind: 'unread', label: 'Ongelezen' });
    for (const g of groups)
      tokens.push({
        key: g.key,
        kind: 'words',
        label: g.words[0]!,
        words: g.words,
      });
    const wordGroups = groups.map((g) => g.words);

    const base: Omit<SearchQuery, 'groups' | 'matchAll' | 'limit'> = inScope(
      {
        people,
        from: plan.from,
        after,
        before,
        folder: plan.folder,
        roles: plan.roles,
        categories,
        unreadOnly: plan.unreadOnly || filters?.unreadOnly,
        hasAttachments: plan.hasAttachments || filters?.hasAttachments,
        includeLow: plan.includeLow || options.includeLow,
        factsOnly: options.factsOnly,
        alsoIds: options.alsoIds,
      },
      scope,
    );
    const passes = (q: typeof base) => {
      const strict = matchingIds(db, mailboxIds, {
        ...q,
        groups: wordGroups,
        matchAll: true,
        limit: 50,
      });
      const loose =
        wordGroups.length > 1
          ? matchingIds(db, mailboxIds, {
              ...q,
              groups: wordGroups,
              matchAll: false,
              limit: 100,
            })
          : strict;
      const lists = [
        { ids: strict.ids, weight: 1.5 },
        { ids: loose.ids, weight: 1 },
      ];
      const vector = options.vector;
      if (vector) {
        const near = this.o.vectors.nearest(vector.model, vector.values, 400);
        if (near.length) {
          const allowed = new Set(
            matchingIds(db, mailboxIds, {
              ...q,
              groups: [],
              matchAll: true,
              onlyIds: near.map((n) => n.id),
              limit: 400,
            }).ids,
          );
          lists.push({
            ids: near
              .filter((n) => allowed.has(n.id))
              .slice(0, 100)
              .map((n) => n.id),
            weight: 1.2,
          });
        }
      }
      // Mail that matches every group is what the person asked for; any group
      // alone counts only when nothing does.
      return { ids: fuse(lists), total: strict.total || loose.total };
    };
    let found = passes(base);
    // A wrong person or a period remembered wrong should not leave nothing.
    if (!found.ids.length && people.length > (filters?.people.length ?? 0)) {
      found = passes({ ...base, people: filters?.people ?? [] });
    }
    if (
      !found.ids.length &&
      (plan.after || plan.before) &&
      !filters?.after &&
      !filters?.before
    ) {
      found = passes({ ...base, after: null, before: null });
    }
    return {
      explanation: plan.explanation,
      tokens,
      wantsAnswer: plan.answer,
      results: load(db, found.ids.slice(0, 50), {
        groups: wordGroups,
        factsOnly: options.factsOnly,
      }),
      plan: original,
      loose: false,
      total: Math.max(found.total, found.ids.length),
      answer: null,
    };
  }

  // Orders the best results by the bot's reading and answers when asked.
  // The ids must already be ones the key may see.
  async rank(
    personId: string,
    question: string,
    ids: readonly string[],
    options: { answer: boolean; factsOnly?: boolean },
  ): Promise<RankResponse> {
    const { catalog, runner, db } = this.o.platform;
    const results = load(db, ids, { groups: [], factsOnly: options.factsOnly });
    if (!this.canRank(personId) || results.length < 2) {
      return { results, relevant: results.length, answer: null };
    }
    const bot = catalog.bots.get(this.o.bot)!;
    const raw = await runner.run({
      ...botRequest(bot, [catalog.skills.get(RANK_SKILL)!]),
      prompt: [
        ...this.about(personId),
        '',
        'Their question:',
        question,
        '',
        options.answer
          ? 'Answer the question if the candidates say it.'
          : 'Do not answer; only rank.',
        '',
        untrusted(
          'candidates',
          results.map((r, i) => candidateLine(r, i + 1)).join('\n'),
        ),
      ].join('\n'),
      schema: rankSchema,
    });
    const answer = ranking.parse(raw);
    const pick = (n: number) => results[n - 1];
    const relevant = [...new Set(answer.relevant)]
      .map(pick)
      .filter((r): r is SearchResult => Boolean(r));
    const rest = results.filter((r) => !relevant.includes(r));
    const from = answer.answerFrom
      .map(pick)
      .filter((r): r is SearchResult => Boolean(r));
    return {
      results: [...relevant, ...rest],
      relevant: relevant.length,
      answer:
        options.answer && answer.answer && from.length
          ? { text: answer.answer, messageIds: from.map((r) => r.id) }
          : null,
    };
  }
}

// One candidate for the bot: no addresses, and only the summary or the first
// lines. Of a sensitive message only the summary goes, with secrets and
// personal numbers replaced, as everywhere a cloud bot reads mail; never its body.
function candidateLine(r: SearchResult, n: number): string {
  const who =
    r.folder === 'sent'
      ? `aan ${r.to.map((a) => a.name || a.email).join(', ')}`
      : `van ${r.from.name || r.from.email}`;
  const date = r.receivedAt.slice(0, 10);
  const text =
    r.facts?.summary ??
    (r.facts?.sensitive ? '(gevoelige mail, geen samenvatting)' : r.snippet);
  return `${n}. ${date} ${who} | ${redact(r.subject)} | ${redact(text).replace(/\s+/g, ' ').slice(0, 300)}`;
}
