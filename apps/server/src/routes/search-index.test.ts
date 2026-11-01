import {
  peopleResponse,
  rankResponse,
  searchResponse,
} from '@burrow/contracts';
import { messageFacts, messages } from '@burrow/hedwig/server';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  const inbox = h.provider(home.id);
  inbox.deliver({
    subject: 'Uw nota van maart',
    from: { name: 'Tandartspraktijk De Kies', email: 'balie@dekies.example' },
    bodyText: 'Bijgaand de nota voor de controle van 12 maart.',
    receivedAt: new Date('2026-03-12T08:00:00Z'),
  });
  inbox.deliver({
    subject: 'Etentje zaterdag?',
    from: { name: 'Jan Bakker', email: 'jan@bakker.example' },
    bodyText:
      'Hoi! We zitten om zeven uur in Café de Zwaan.\n\nNeem jij de factuur van de catering mee?',
    receivedAt: new Date('2026-03-20T08:00:00Z'),
  });
  inbox.deliver({
    subject: 'Factuur 2026-031',
    from: { name: 'Studio Vos', email: 'admin@vos.example' },
    bodyText: 'In de bijlage de factuur voor februari.',
    receivedAt: new Date('2026-02-02T08:00:00Z'),
  });
  inbox.deliver({
    subject: 'Offerte website',
    from: { name: 'Gideon', email: 'gideon@example.com' },
    to: [{ name: 'Jan de Vries', email: 'jan@devries.example' }],
    folder: 'sent',
    bodyText: 'Zoals besproken de offerte voor de nieuwe website.',
    receivedAt: new Date('2026-04-01T08:00:00Z'),
  });
  inbox.deliver({
    subject: 'Nog een offerte',
    from: { name: 'Gideon', email: 'gideon@example.com' },
    to: [{ name: 'Jan de Vries', email: 'jan@devries.example' }],
    folder: 'sent',
    bodyText: 'En hier de tweede.',
    receivedAt: new Date('2026-04-02T08:00:00Z'),
  });
  inbox.deliver({
    subject: 'Rooster les 4',
    from: { name: 'Vakgroep Biologie', email: 'bio@hogeschool.example' },
    bodyText: 'Het practicum verschuift naar donderdag.',
    receivedAt: new Date('2026-05-04T08:00:00Z'),
  });
  inbox.deliver({
    subject: 'Tentamen',
    from: { name: 'Studiebalie', email: 'balie@hogeschool.example' },
    bodyText: 'Inschrijven kan tot vrijdag.',
    receivedAt: new Date('2026-05-05T08:00:00Z'),
  });
  h.provider(evas.id).deliver({ subject: 'Factuur tandarts Eva' });
  for (const box of [home, evas]) await h.mail.sync(box.id);
  const id = (subject: string) =>
    h.db.select().from(messages).where(eq(messages.subject, subject)).get()!.id;
  return { ...h, gideon, home, evas, id, token: h.key(gideon.id, ['read']) };
}

type Setup = Awaited<ReturnType<typeof setup>>;
const search = async (s: Setup, query: string) =>
  searchResponse.parse(
    await (await s.call(s.token, `/api/search?${query}`)).json(),
  );
const subjects = async (s: Setup, query: string) =>
  (await search(s, query)).results.map((m) => m.subject);

describe('word search on the index', () => {
  it('finds a word inside a longer Dutch word it starts', async () => {
    const s = await setup();
    expect(await subjects(s, 'q=tandarts')).toEqual(['Uw nota van maart']);
  });

  it('ignores accents and case', async () => {
    const s = await setup();
    expect(await subjects(s, 'q=CAFE%20zwaan')).toEqual(['Etentje zaterdag?']);
  });

  it('finds the word being typed from two letters on, and waits on one', async () => {
    const s = await setup();
    expect((await subjects(s, 'q=fa')).sort()).toEqual([
      'Etentje zaterdag?',
      'Factuur 2026-031',
    ]);
    expect(await subjects(s, 'q=f')).toEqual([]);
  });

  it('leaves out words after a minus and keeps quoted phrases whole', async () => {
    const s = await setup();
    expect(await subjects(s, 'q=factuur%20-catering')).toEqual([
      'Factuur 2026-031',
    ]);
    expect(await subjects(s, 'q=%22factuur%20voor%20februari%22')).toEqual([
      'Factuur 2026-031',
    ]);
  });

  it('marks where a result matched, so the list can show it', async () => {
    const s = await setup();
    const [hit] = (await search(s, 'q=catering')).results;
    expect(hit!.hit!.text).toContain('factuur van de catering mee?');
    const [[start, length]] = hit!.hit!.ranges as [[number, number]];
    expect(hit!.hit!.text.slice(start, start + length)).toBe('catering');
    expect(hit!.hit!.text).not.toContain('\n');
  });

  it('counts every match, not only the page it returns', async () => {
    const s = await setup();
    const found = await search(s, 'q=de&limit=1');
    expect(found.results).toHaveLength(1);
    expect(found.total).toBeGreaterThan(1);
  });

  it('follows the facts: a summary written later is found', async () => {
    const s = await setup();
    expect(await subjects(s, 'q=gebitscontrole')).toEqual([]);
    s.db
      .update(messageFacts)
      .set({ summary: 'Rekening voor de halfjaarlijkse gebitscontrole' })
      .where(eq(messageFacts.messageId, s.id('Uw nota van maart')))
      .run();
    expect(await subjects(s, 'q=gebitscontrole')).toEqual([
      'Uw nota van maart',
    ]);
  });

  it('forgets a message once it is gone', async () => {
    const s = await setup();
    s.db
      .delete(messages)
      .where(eq(messages.id, s.id('Rooster les 4')))
      .run();
    expect(await subjects(s, 'q=practicum')).toEqual([]);
  });
});

describe('@people', () => {
  const people = async (s: Setup, q: string) =>
    peopleResponse.parse(
      await (
        await s.call(s.token, `/api/search/people?q=${encodeURIComponent(q)}`)
      ).json(),
    ).people;

  it('offers the people someone mails with, the ones they write to first', async () => {
    const s = await setup();
    const found = await people(s, 'jan');
    expect(found.map((p) => p.name)).toEqual(['Jan de Vries', 'Jan Bakker']);
    expect(found[0]).toMatchObject({
      emails: ['jan@devries.example'],
      sent: 2,
    });
  });

  it('never offers the person themself or someone else’s contacts', async () => {
    const s = await setup();
    expect((await people(s, 'gideon')).map((p) => p.name)).toEqual([]);
    expect((await people(s, 'someone')).map((p) => p.name)).toEqual([]);
  });

  it('offers everyone at a domain once several people write from it', async () => {
    const s = await setup();
    const found = await people(s, 'hogeschool');
    expect(found[0]).toMatchObject({
      name: 'hogeschool.example',
      emails: ['@hogeschool.example'],
      domain: true,
    });
    expect(await subjects(s, 'people=%40hogeschool.example')).toEqual([
      'Tentamen',
      'Rooster les 4',
    ]);
  });

  it('limits a search to mail from or to a person, newest first', async () => {
    const s = await setup();
    expect(await subjects(s, 'q=%40jan')).toEqual([
      'Nog een offerte',
      'Offerte website',
    ]);
    expect(await subjects(s, 'q=%40bakker')).toEqual(['Etentje zaterdag?']);
    expect(await subjects(s, 'people=jan@bakker.example&q=factuur')).toEqual([
      'Etentje zaterdag?',
    ]);
  });

  it('combines a person with a period', async () => {
    const s = await setup();
    expect(
      await subjects(
        s,
        'people=jan@devries.example&after=2026-04-02&before=2026-05-01',
      ),
    ).toEqual(['Nog een offerte']);
  });
});

describe('search by meaning, step by step', () => {
  const plan = (over: object) => ({
    groups: [],
    people: [],
    from: null,
    after: null,
    before: null,
    folder: null,
    roles: null,
    unreadOnly: false,
    hasAttachments: false,
    categories: null,
    includeLow: false,
    answer: false,
    explanation: 'Zoekt',
    ...over,
  });
  const ask = async (s: Setup, question: string) =>
    searchResponse.parse(
      await (
        await s.call(s.token, '/api/search/ai', {
          method: 'POST',
          body: JSON.stringify({ question }),
        })
      ).json(),
    );

  it('looks the plan’s people up and shows the plan as tokens', async () => {
    const s = await setup();
    s.decisions.push(
      plan({
        groups: [['offerte', 'voorstel']],
        people: ['Jan de Vries'],
        after: '2026-04-01',
        before: '2026-05-01',
        explanation: 'Offertes aan Jan, april 2026',
      }),
    );
    const found = await ask(s, 'de offerte die ik Jan stuurde in april');
    expect(found.results.map((m) => m.subject)).toEqual([
      'Nog een offerte',
      'Offerte website',
    ]);
    expect(found.tokens).toEqual([
      {
        key: 'people:0',
        kind: 'person',
        label: 'Jan de Vries',
        emails: ['jan@devries.example'],
      },
      {
        key: 'period',
        kind: 'period',
        label: 'april 2026',
        after: '2026-04-01',
        before: '2026-05-01',
      },
      {
        key: 'group:0',
        kind: 'words',
        label: 'offerte',
        words: ['offerte', 'voorstel'],
      },
    ]);

    // Dropping the person reruns the same plan without the bot.
    const asked = s.agentRequests.length;
    const wider = searchResponse.parse(
      await (
        await s.call(s.token, '/api/search/ai', {
          method: 'POST',
          body: JSON.stringify({
            question: 'de offerte die ik Jan stuurde in april',
            plan: found.plan,
            without: ['people:0', 'period'],
          }),
        })
      ).json(),
    );
    expect(s.agentRequests.length).toBe(asked);
    expect(wider.tokens.map((t) => t.key)).toEqual(['group:0']);
    expect(wider.results.map((m) => m.subject).sort()).toEqual([
      'Nog een offerte',
      'Offerte website',
    ]);
  });

  it('searches a name nobody mails with as a word, and drops a period that finds nothing', async () => {
    const s = await setup();
    s.decisions.push(
      plan({ people: ['Zwaan'], after: '2025-01-01', before: '2025-02-01' }),
    );
    const found = await ask(s, 'dat etentje in café de zwaan');
    expect(found.results.map((m) => m.subject)).toEqual(['Etentje zaterdag?']);
  });

  it('ranks matches of every group above matches of one', async () => {
    const s = await setup();
    s.decisions.push(
      plan({
        groups: [
          ['factuur', 'nota'],
          ['tandarts', 'kies'],
        ],
      }),
    );
    const found = await ask(s, 'rekening tandarts');
    expect(found.results[0]!.subject).toBe('Uw nota van maart');
    expect(found.results.map((m) => m.subject)).toContain('Factuur 2026-031');
  });

  it('lets the bot order the best results and answer from them, fenced as untrusted', async () => {
    const s = await setup();
    const ids = [
      s.id('Factuur 2026-031'),
      s.id('Rooster les 4'),
      s.id('Tentamen'),
    ];
    s.decisions.push({
      relevant: [2],
      answer: 'Het practicum is verschoven naar donderdag.',
      answerFrom: [2],
    });
    const res = await s.call(s.token, '/api/search/ai/rank', {
      method: 'POST',
      body: JSON.stringify({
        question: 'wanneer is het practicum?',
        messageIds: ids,
        answer: true,
      }),
    });
    const ranked = rankResponse.parse(await res.json());
    expect(ranked.results.map((m) => m.subject)).toEqual([
      'Rooster les 4',
      'Factuur 2026-031',
      'Tentamen',
    ]);
    expect(ranked.relevant).toBe(1);
    expect(ranked.answer).toEqual({
      text: 'Het practicum is verschoven naar donderdag.',
      messageIds: [s.id('Rooster les 4')],
    });
    const prompt = s.agentRequests.at(-1)!.prompt;
    expect(prompt).toMatch(
      /<candidates>[\s\S]*Rooster les 4[\s\S]*<\/candidates>/,
    );
    expect(prompt).not.toContain('bio@hogeschool.example');
  });

  it('never lets the bot read mail outside the key, and skips it when the person said no', async () => {
    const s = await setup();
    const eva = s.db
      .select()
      .from(messages)
      .where(eq(messages.mailboxId, s.evas.id))
      .get()!;
    s.platform.settings.update(s.gideon.id, { 'hedwig.searchReads': false });
    const before = s.agentRequests.length;
    const res = await s.call(s.token, '/api/search/ai/rank', {
      method: 'POST',
      body: JSON.stringify({
        question: 'facturen',
        messageIds: [
          eva.id,
          s.id('Factuur 2026-031'),
          s.id('Uw nota van maart'),
        ],
      }),
    });
    const ranked = rankResponse.parse(await res.json());
    expect(ranked.results.map((m) => m.subject)).toEqual([
      'Factuur 2026-031',
      'Uw nota van maart',
    ]);
    expect(s.agentRequests.length).toBe(before);
  });

  it('tells the planner what the person said about themselves', async () => {
    const s = await setup();
    s.platform.settings.update(s.gideon.id, {
      'hedwig.searchAbout':
        'Ik studeer; schoolmail gaat over vakken en roosters.',
    });
    s.decisions.push(plan({ groups: [['rooster']] }));
    await ask(s, 'wanneer heb ik les?');
    expect(s.agentRequests.at(-1)!.prompt).toContain(
      'Ik studeer; schoolmail gaat over vakken en roosters.',
    );
  });
});
