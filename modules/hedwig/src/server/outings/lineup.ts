import { type LineupRead, lineupRead } from '@burrow/contracts';
import { botRequest, type Platform, untrusted } from '@burrow/platform';
import { eq } from 'drizzle-orm';
import { z } from 'zod';
import { decodeEntities, htmlToText } from '../../html';
import { outingLineups, outings } from '../schema';
import { type FetchPublic, pageLimit } from './images';

export const LINEUP_SKILL = 'festival-lineup';
const schema = z.toJSONSchema(lineupRead, { target: 'draft-7' });
// Pages next to the home page that may name acts: the line-up itself and
// the latest news, where festivals announce names one by one.
const LINEUP_PATH =
  /line-?up|programm|timetable|tijdschema|speelschema|artist|acts\b|bands?\b/i;
const NEWS_PATH = /\/(nieuws|news|actua\w*|blog)\//i;
const MAX_PAGES = 8;
const PAGE_CHARS = 5_000;

export class LineupError extends Error {}

// The line-up widget: the server fetches the event's own pages, Haiku reads
// the acts from them. Only the server goes online, and only to public pages.
export class OutingLineups {
  private readonly running = new Map<string, Promise<void>>();
  readonly on: boolean;

  constructor(
    private readonly o: {
      platform: Platform;
      fetch: FetchPublic;
      bot?: string;
      changed: (id: string) => void;
    },
  ) {
    const { catalog } = o.platform;
    const bot = o.bot ? catalog.bots.get(o.bot) : undefined;
    this.on = Boolean(
      bot &&
      bot.agent !== 'local' &&
      bot.skills.includes(LINEUP_SKILL) &&
      catalog.skills.has(LINEUP_SKILL),
    );
  }

  private get db() {
    return this.o.platform.db;
  }

  // Starts a refresh and returns at once; the outing says "working" until
  // Haiku answers. Tests await the returned promise.
  refresh(id: string): Promise<void> {
    if (!this.on) throw new LineupError('no bot reads line-ups');
    const row = this.db.select().from(outings).where(eq(outings.id, id)).get();
    if (!row) throw new LineupError('not found');
    if (!row.url) {
      throw new LineupError(
        'the outing has no website to read the line-up from',
      );
    }
    let run = this.running.get(id);
    if (!run) {
      this.save(id, { status: 'working', error: null });
      run = this.read(id, row.url, row.title, row.startsAt, row.endsAt)
        .catch((error: Error) => {
          this.save(id, {
            status: 'failed',
            error: error.message.slice(0, 300),
          });
        })
        .finally(() => {
          this.running.delete(id);
          this.o.changed(id);
        });
      this.running.set(id, run);
    }
    return run;
  }

  remove(id: string) {
    this.db.delete(outingLineups).where(eq(outingLineups.outingId, id)).run();
  }

  get(id: string) {
    return this.db
      .select()
      .from(outingLineups)
      .where(eq(outingLineups.outingId, id))
      .get();
  }

  private async read(
    id: string,
    url: string,
    title: string,
    startsAt: Date,
    endsAt: Date | null,
  ) {
    const pages = await this.pages(url);
    if (!pages.length) throw new LineupError('the website could not be read');
    const { catalog, runner } = this.o.platform;
    const bot = catalog.bots.get(this.o.bot!)!;
    const day = (d: Date) => d.toLocaleDateString('sv-SE');
    const prompt = [
      `The event: ${title}, ${day(startsAt)}${endsAt ? ` to ${day(endsAt)}` : ''}.`,
      'Its pages:',
      ...pages.map(
        (p) => `## ${p.url}\n${untrusted('untrusted_page', p.text)}`,
      ),
    ].join('\n\n');
    const answer = lineupRead.parse(
      trim(
        await runner.run({
          ...botRequest(bot, [catalog.skills.get(LINEUP_SKILL)!]),
          prompt,
          schema,
        }),
      ),
    );
    this.save(id, {
      status: 'ready',
      error: null,
      ...answer,
      artists: unique(answer.artists),
      sources: pages.map((p) => p.url),
    });
  }

  private async pages(start: string) {
    const out: { url: string; text: string }[] = [];
    const home = await this.o.fetch(start, pageLimit).catch(() => undefined);
    if (!home || home.contentType !== 'text/html') return out;
    const html = Buffer.from(home.data).toString('utf8');
    out.push({ url: home.url, text: pageText(html) });
    for (const link of pageLinks(html, home.url)) {
      if (out.length >= MAX_PAGES) break;
      const page = await this.o.fetch(link, pageLimit).catch(() => undefined);
      if (page?.contentType !== 'text/html') continue;
      out.push({
        url: page.url,
        text: pageText(Buffer.from(page.data).toString('utf8')),
      });
    }
    return out;
  }

  private save(id: string, fields: Partial<typeof outingLineups.$inferInsert>) {
    const now = new Date();
    this.db
      .insert(outingLineups)
      .values({ outingId: id, status: 'working', updatedAt: now, ...fields })
      .onConflictDoUpdate({
        target: outingLineups.outingId,
        set: { ...fields, updatedAt: now },
      })
      .run();
  }
}

// Line-up pages first, then the newest news, all on the event's own site.
export function pageLinks(html: string, base: string): string[] {
  const host = new URL(base).hostname.replace(/^www\./, '');
  const lineup: string[] = [];
  const news: string[] = [];
  for (const m of html.matchAll(/href\s*=\s*"([^"#]+)"/gi)) {
    let url: URL;
    try {
      url = new URL(decodeEntities(m[1]!), base);
    } catch {
      continue;
    }
    if (!/^https?:$/.test(url.protocol)) continue;
    if (url.hostname.replace(/^www\./, '') !== host) continue;
    const href = url.toString();
    if (href === base || lineup.includes(href) || news.includes(href)) continue;
    if (LINEUP_PATH.test(url.pathname)) lineup.push(href);
    else if (NEWS_PATH.test(url.pathname)) news.push(href);
  }
  return [...lineup.slice(0, 3), ...news];
}

export function pageText(html: string) {
  return htmlToText(
    html.replace(/<(nav|footer|noscript)[\s\S]*?<\/\1>/gi, ''),
  ).slice(0, PAGE_CHARS);
}

function unique(artists: LineupRead['artists']) {
  const seen = new Set<string>();
  return artists.filter((a) => {
    const key = a.name.trim().toLowerCase();
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// Small models overshoot limits; cut instead of failing the whole answer.
function trim(raw: unknown): unknown {
  if (!raw || typeof raw !== 'object') return raw;
  const r = raw as Record<string, unknown>;
  return {
    ...r,
    note: typeof r.note === 'string' ? r.note.slice(0, 200) : r.note,
    artists: Array.isArray(r.artists) ? r.artists.slice(0, 400) : r.artists,
  };
}
