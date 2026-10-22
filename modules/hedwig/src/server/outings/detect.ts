import type { Address, OutingSuggestion } from '@burrow/contracts';

export type DetectInput = {
  subject: string;
  from: Address;
  bodyText: string | null;
  bodyHtml: string | null;
  receivedAt: Date;
  // ISO days from the mail facts, when there are any.
  dates?: string[];
  // Whether the mail has attachments, before they are fetched.
  hasAttachments?: boolean;
  attachments: {
    id: string;
    name: string;
    contentType: string;
    size: number;
    inline: boolean;
  }[];
};

export type Detected = Omit<OutingSuggestion, 'outingId'>;

// Ticket shops by a word in the sender's domain.
const SHOPS: [RegExp, string][] = [
  [/weeztix|eventix/, 'Weeztix'],
  [/ticketmaster/, 'Ticketmaster'],
  [/eventbrite/, 'Eventbrite'],
  [/paylogic/, 'Paylogic'],
  [/seetickets/, 'See Tickets'],
  [/ticketswap/, 'TicketSwap'],
  [/stager/, 'Stager'],
  [/ticketmatic/, 'Ticketmatic'],
  [/ticketcounter/, 'Ticketcounter'],
  [/tibbaa/, 'Tibbaa'],
  [/ticketpoint/, 'Ticketpoint'],
  // Lockers at festivals: not a ticket, but part of the night.
  [/eventsafe/, 'Eventsafe'],
];

// Attachments that come with tickets but are none.
const NOT_TICKETS =
  /terms|voorwaarden|conditions|invoice|factuur|receipt|kwitantie|privacy|bon\b/i;

const TICKET_WORDS =
  /\b(e-?tickets?|tickets?|kaarten|kaartjes|toegangsbewijs|entreebewijs|polsband)\b/i;

const KINDS: [RegExp, string][] = [
  [/\bfestival\b/i, 'festival'],
  [/\bconcert\b|\btour\b/i, 'concert'],
  [/\btheater\b|\bvoorstelling\b|\bmusical\b/i, 'theater'],
  [/\bcabaret\b|\bcomedy\b/i, 'cabaret'],
  [/\bparty\b|\bfeest\b/i, 'feest'],
];

const SCHEMA_KINDS: Record<string, string> = {
  MusicEvent: 'concert',
  Festival: 'festival',
  TheaterEvent: 'theater',
  ComedyEvent: 'cabaret',
  DanceEvent: 'feest',
  SportsEvent: 'sport',
  ScreeningEvent: 'film',
};

const MONTHS: Record<string, number> = {
  jan: 0,
  januari: 0,
  january: 0,
  feb: 1,
  februari: 1,
  february: 1,
  mrt: 2,
  maart: 2,
  mar: 2,
  march: 2,
  apr: 3,
  april: 3,
  mei: 4,
  may: 4,
  jun: 5,
  juni: 5,
  june: 5,
  jul: 6,
  juli: 6,
  july: 6,
  aug: 7,
  augustus: 7,
  august: 7,
  sep: 8,
  sept: 8,
  september: 8,
  okt: 9,
  oktober: 9,
  oct: 9,
  october: 9,
  nov: 10,
  november: 10,
  dec: 11,
  december: 11,
};
const MONTH_NAMES = Object.keys(MONTHS)
  .sort((a, b) => b.length - a.length)
  .join('|');
// "13 mei 2027", "13-05-2027", "2027-05-13", each with an optional "20:00".
const DATE = new RegExp(
  String.raw`(\d{4})-(\d{2})-(\d{2})|(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})|(\d{1,2})\s+(${MONTH_NAMES})\.?\s+(\d{4})`,
  'i',
);
const TIME = /^\D{0,12}?(\d{1,2})[:.](\d{2})\b/;

// Reads what a mail says about an outing it sells tickets for. Structured
// data (schema.org) wins; otherwise the shop, the subject and the text.
export function detectOuting(input: DetectInput): Detected {
  const text = input.bodyText ?? '';
  const event = schemaEvent(input.bodyHtml);
  const domain = input.from.email.split('@')[1]?.toLowerCase() ?? '';
  const shop = SHOPS.find(([pattern]) => pattern.test(domain))?.[1] ?? null;
  const ticketish = TICKET_WORDS.test(
    `${input.subject} ${text.slice(0, 3000)}`,
  );

  const fromSubject = titleFromSubject(input.subject);
  const title = event?.name ?? fromSubject ?? input.subject.trim();
  const startsAt =
    date(event?.startDate) ?? firstFutureDate(text, input.receivedAt);
  const kind =
    event?.kind ??
    KINDS.find(([pattern]) => pattern.test(`${input.subject} ${text}`))?.[1] ??
    null;
  const vendor =
    event?.vendor ??
    shop ??
    (ticketish ? input.from.name?.trim() || null : null);
  const orderNumber = event?.orderNumber ?? orderFrom(text);
  const personaliseBy = personaliseDeadline(text, startsAt);
  const tickets = input.attachments
    .filter(
      (a) =>
        !a.inline &&
        !NOT_TICKETS.test(a.name) &&
        (a.contentType === 'application/pdf' ||
          a.contentType === 'application/vnd.apple.pkpass' ||
          /\.(pdf|pkpass)$/i.test(a.name) ||
          (a.contentType.startsWith('image/') && a.size >= 10_000)),
    )
    .map(({ id, name, contentType, size }) => ({
      id,
      name,
      contentType,
      size,
    }));

  const confidence: Detected['confidence'] = event
    ? 'structured'
    : shop ||
        fromSubject ||
        (ticketish && (startsAt || tickets.length || input.hasAttachments))
      ? 'likely'
      : 'none';
  const venue = event?.venue ?? null;
  const organiser = event?.organiser ?? null;
  return {
    title,
    kind,
    startsAt: startsAt?.toISOString() ?? null,
    endsAt: date(event?.endDate)?.toISOString() ?? null,
    doorsAt: date(event?.doorTime)?.toISOString() ?? null,
    venue,
    address: event?.address ?? null,
    organiser,
    vendor,
    orderNumber,
    url: event?.url ?? null,
    personaliseBy: personaliseBy?.toISOString() ?? null,
    aliases: unique([title, kind, organiser, vendor, venue, orderNumber]),
    tickets,
    confidence,
  };
}

type SchemaEvent = {
  name?: string;
  kind?: string;
  startDate?: string;
  endDate?: string;
  doorTime?: string;
  venue?: string;
  address?: string;
  organiser?: string;
  vendor?: string;
  orderNumber?: string;
  url?: string;
};

type Json = Record<string, unknown>;
const str = (v: unknown) =>
  typeof v === 'string' && v.trim() ? v.trim() : undefined;
const nameOf = (v: unknown) => str(v) ?? str((v as Json | undefined)?.name);
const types = (v: Json) => [v['@type']].flat().map(String);

// The first schema.org EventReservation or Event in the mail's JSON-LD.
export function schemaEvent(html: string | null): SchemaEvent | undefined {
  if (!html) return undefined;
  const blocks = html.matchAll(
    /<script[^>]*type\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi,
  );
  for (const [, body] of blocks) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(body!.trim());
    } catch {
      continue;
    }
    const nodes = [parsed]
      .flat()
      .flatMap((n) => [n, ...[(n as Json)?.['@graph'] ?? []].flat()]) as Json[];
    for (const node of nodes) {
      if (!node || typeof node !== 'object') continue;
      const reservation = types(node).includes('EventReservation');
      const event = (reservation ? node.reservationFor : node) as
        | Json
        | undefined;
      if (
        !event ||
        !types(event).some((t) => t.endsWith('Event') || t === 'Festival')
      )
        continue;
      const location = [event.location].flat()[0] as Json | undefined;
      return {
        name: str(event.name),
        kind: types(event)
          .map((t) => SCHEMA_KINDS[t])
          .find(Boolean),
        startDate: str(event.startDate),
        endDate: str(event.endDate),
        doorTime: str(event.doorTime),
        venue: nameOf(location),
        address: postal(location?.address),
        organiser: nameOf(event.organizer),
        vendor: reservation
          ? (nameOf(node.broker) ?? nameOf(node.provider))
          : undefined,
        orderNumber: reservation ? str(node.reservationNumber) : undefined,
        url: str(event.url),
      };
    }
  }
  return undefined;
}

function postal(v: unknown): string | undefined {
  if (typeof v === 'string') return str(v);
  if (!v || typeof v !== 'object') return undefined;
  const a = v as Json;
  const line = [
    str(a.streetAddress),
    [str(a.postalCode), str(a.addressLocality)].filter(Boolean).join(' '),
  ]
    .filter(Boolean)
    .join(', ');
  return line || undefined;
}

function date(value: string | undefined): Date | null {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

function titleFromSubject(subject: string): string | null {
  const m =
    /(?:ticket(?:s|\(s\))?|kaarten|kaartjes|e-?tickets?|bestelling|order)\s+(?:voor|for)\s+["'„]?(.+?)["'”]?(?:\s+(?:is|zijn|are|is now)\s+\S+)?[.!]?\s*$/i.exec(
      subject.trim(),
    );
  return m?.[1]?.trim() || null;
}

function orderFrom(text: string): string | null {
  const m =
    /(?:bestel(?:nummer|ling(?:snummer)?)|ordernummer|ordernr\.?|order\s*(?:number|no\.?|id|#)|reserverings?nummer|booking\s+reference)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{4,})/i.exec(
      text,
    );
  return m && /\d/.test(m[1]!) ? m[1]! : null;
}

// Every date in the text, with its time when one follows.
export function datesIn(text: string): Date[] {
  const found: Date[] = [];
  const re = new RegExp(DATE.source, 'gi');
  for (const m of text.matchAll(re)) {
    let y: number;
    let mo: number;
    let d: number;
    if (m[1]) [y, mo, d] = [Number(m[1]), Number(m[2]) - 1, Number(m[3])];
    else if (m[6]) [y, mo, d] = [Number(m[6]), Number(m[5]) - 1, Number(m[4])];
    else
      [y, mo, d] = [Number(m[9]), MONTHS[m[8]!.toLowerCase()]!, Number(m[7])];
    if (mo < 0 || mo > 11 || d < 1 || d > 31) continue;
    const time = TIME.exec(text.slice(m.index! + m[0].length));
    const [h, min] = time ? [Number(time[1]), Number(time[2])] : [0, 0];
    found.push(new Date(y, mo, d, h < 24 ? h : 0, min < 60 ? min : 0));
  }
  return found;
}

function firstFutureDate(text: string, after: Date): Date | null {
  return datesIn(text).find((d) => d.getTime() > after.getTime()) ?? null;
}

// "uiterlijk 14 dagen voor het evenement op naam" or "op naam zetten vóór 29
// april 2027".
export function personaliseDeadline(
  text: string,
  startsAt: Date | null,
): Date | null {
  if (!/op naam|personali[sz]/i.test(text)) return null;
  const relative =
    /(?:uiterlijk|tot|no later than|at least)\s+(\d{1,3})\s+(?:dagen|days)\s+(?:voor|vóór|before)/i.exec(
      text,
    );
  if (relative && startsAt) {
    return new Date(startsAt.getTime() - Number(relative[1]) * 86_400_000);
  }
  const absolute =
    /(?:op naam|personali[sz]\w*)[^]{0,160}?(?:vóór|voor|uiterlijk|tot|before|by|until)\s+(?:\w+dag\s+)?/i.exec(
      text,
    );
  if (absolute) {
    const rest = text.slice(
      absolute.index + absolute[0].length,
      absolute.index + absolute[0].length + 40,
    );
    const [d] = datesIn(rest);
    if (d && rest.search(DATE) === 0) return d;
  }
  return null;
}

export function unique(values: (string | null | undefined)[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of values) {
    const t = v?.trim();
    if (!t || seen.has(t.toLowerCase())) continue;
    seen.add(t.toLowerCase());
    out.push(t);
  }
  return out;
}

const LINK_WORDS =
  /download|ticket|kaart|bekijk|view|wallet|claim|bestelling|order/i;
const LINK_PATH =
  /\/download\b|\/e?-?tickets?\b|\/order\b|personali[sz]ation|wallet|pkpass/i;
// Whole words only: tracking links carry random tokens.
const NOT_A_TICKET_LINK =
  /\b(support|help|faq|adobe|reader|terms|voorwaarden|privacy|unsubscribe|afmeld\w*|uitschrijv\w*|facebook|instagram|twitter|tiktok|youtube|linkedin|contact|webversion|webversie|browser)\b|maps\./i;

// Links in an order mail to the page where the shop keeps the tickets:
// "Download je tickets", "Ticket bekijken". At most two, downloads first.
export function ticketLinks(html: string | null): string[] {
  if (!html) return [];
  const found: { url: string; download: boolean }[] = [];
  for (const m of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/gi)) {
    const href = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(m[1]!);
    const url = (href?.[1] ?? href?.[2] ?? '').replaceAll('&amp;', '&').trim();
    if (!/^https:\/\//i.test(url)) continue;
    let path: string;
    let where: string;
    try {
      const target = new URL(safeDecode(url));
      path = target.pathname;
      where = target.hostname + target.pathname;
    } catch {
      continue;
    }
    const title = /\btitle\s*=\s*"([^"]*)"/i.exec(m[1]!)?.[1] ?? '';
    const text = `${title} ${m[2]!
      .replace(/<img\b[^>]*\balt\s*=\s*"([^"]*)"[^>]*>/gi, ' $1 ')
      .replace(/<[^>]+>/g, ' ')}`;
    if (NOT_A_TICKET_LINK.test(where) || NOT_A_TICKET_LINK.test(text)) continue;
    if (!LINK_PATH.test(path) || !LINK_WORDS.test(`${text} ${path}`)) continue;
    if (found.some((f) => f.url === url)) continue;
    found.push({ url, download: /download/i.test(`${text} ${path}`) });
  }
  return found
    .sort((a, b) => Number(b.download) - Number(a.download))
    .slice(0, 2)
    .map((f) => f.url);
}

function safeDecode(url: string) {
  try {
    return decodeURIComponent(url);
  } catch {
    return url;
  }
}
