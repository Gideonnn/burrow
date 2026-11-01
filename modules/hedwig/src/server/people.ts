import type { MailPerson } from '@burrow/contracts';
import type { Db } from '@burrow/platform';
import { inArray, sql } from 'drizzle-orm';
import { mailContacts } from './schema';
import { fold, tokens } from './search-text';

// Addresses that say nothing about who is behind them; their domain is never
// offered as "everyone at".
const SHARED_DOMAINS = new Set([
  'gmail.com',
  'googlemail.com',
  'hotmail.com',
  'hotmail.nl',
  'outlook.com',
  'outlook.nl',
  'live.com',
  'live.nl',
  'icloud.com',
  'me.com',
  'mac.com',
  'yahoo.com',
  'proton.me',
  'protonmail.com',
  'fastmail.com',
  'ziggo.nl',
  'kpnmail.nl',
  'planet.nl',
  'xs4all.nl',
]);

type Contact = {
  email: string;
  name: string | null;
  sent: number;
  received: number;
  lastAt: number;
};

// Mail to someone says more than mail from them; both fade over a year.
function weight(
  c: { sent: number; received: number; lastAt: number },
  now: number,
) {
  const days = Math.max(0, (now - c.lastAt) / 86_400_000);
  return (3 * c.sent + c.received) * (0.25 + 0.75 * 0.5 ** (days / 365));
}

function contacts(db: Db, mailboxIds: readonly string[]): Contact[] {
  if (!mailboxIds.length) return [];
  return db
    .select({
      email: mailContacts.email,
      name: sql<string | null>`max(${mailContacts.name})`,
      sent: sql<number>`sum(${mailContacts.sent})`,
      received: sql<number>`sum(${mailContacts.received})`,
      lastAt: sql<number>`max(${mailContacts.lastAt})`,
    })
    .from(mailContacts)
    .where(inArray(mailContacts.mailboxId, [...mailboxIds]))
    .groupBy(mailContacts.email)
    .all();
}

// A name of two words or more is one person, whatever address they wrote
// from; a single word ("Jan", "Info") is not enough to merge on.
const personKey = (c: Contact) => {
  const t = tokens(c.name ?? '');
  return t.length >= 2 ? `name:${t.join(' ')}` : `email:${c.email}`;
};

const displayName = (c: Contact) => c.name?.trim() || c.email;

// The people a person corresponds with whose name or address starts with
// what they typed after @, most corresponded with first. An empty query
// gives the people mailed most.
export function findPeople(
  db: Db,
  mailboxIds: readonly string[],
  q: string,
  limit = 8,
  now = Date.now(),
): MailPerson[] {
  const wanted = tokens(q.replace(/^@/, ''));
  const typed = fold(q.replace(/^@/, '').trim());
  const people = new Map<
    string,
    { contacts: Contact[]; weight: number; name: string }
  >();
  const domains = new Map<string, { contacts: Contact[]; weight: number }>();
  for (const c of contacts(db, mailboxIds)) {
    const [local = '', domain = ''] = c.email.split('@');
    const words = [...tokens(c.name ?? ''), ...tokens(local)];
    const domainWords = tokens(domain);
    const byName = wanted.every((w) => words.some((t) => t.startsWith(w)));
    const byDomain =
      typed.length >= 3 &&
      !SHARED_DOMAINS.has(domain) &&
      (domain.startsWith(typed) ||
        domainWords.some((t) => t.startsWith(typed)));
    if (byDomain) {
      const d = domains.get(domain) ?? { contacts: [], weight: 0 };
      d.contacts.push(c);
      d.weight += weight(c, now);
      domains.set(domain, d);
    }
    if (!byName && !c.email.startsWith(typed)) continue;
    const key = personKey(c);
    const p = people.get(key) ?? {
      contacts: [],
      weight: 0,
      name: displayName(c),
    };
    p.contacts.push(c);
    p.weight += weight(c, now);
    if (
      c.name &&
      (p.name === p.contacts[0]!.email || c.sent > p.contacts[0]!.sent)
    )
      p.name = c.name.trim();
    people.set(key, p);
  }
  const found: (MailPerson & { weight: number })[] = [...people.values()].map(
    (p) => ({
      name: p.name,
      emails: p.contacts
        .sort((a, b) => weight(b, now) - weight(a, now))
        .map((c) => c.email),
      sent: p.contacts.reduce((n, c) => n + c.sent, 0),
      received: p.contacts.reduce((n, c) => n + c.received, 0),
      lastAt: new Date(
        Math.max(...p.contacts.map((c) => c.lastAt)),
      ).toISOString(),
      domain: false,
      weight: p.weight,
    }),
  );
  for (const [domain, d] of domains) {
    // A domain is worth offering once several people write from it.
    if (d.contacts.length < 2) continue;
    found.push({
      name: domain,
      emails: [`@${domain}`],
      sent: d.contacts.reduce((n, c) => n + c.sent, 0),
      received: d.contacts.reduce((n, c) => n + c.received, 0),
      lastAt: new Date(
        Math.max(...d.contacts.map((c) => c.lastAt)),
      ).toISOString(),
      domain: true,
      weight: d.weight * 0.9,
    });
  }
  return found
    .sort((a, b) => b.weight - a.weight)
    .slice(0, limit)
    .map(({ name, emails, sent, received, lastAt, domain }) => ({
      name,
      emails,
      sent,
      received,
      lastAt,
      domain,
    }));
}
