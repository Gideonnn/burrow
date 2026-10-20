import { searchResponse } from '@burrow/contracts';
import { mailboxes } from '@burrow/hedwig/server';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const work = h.mailbox(gideon.id, 'gideon@studio.example');
  h.db
    .update(mailboxes)
    .set({ role: 'work' })
    .where(eq(mailboxes.id, work.id))
    .run();
  const evas = h.mailbox(eva.id, 'eva@example.com');
  h.provider(home.id).deliver({
    subject: 'Uw nota van maart',
    from: { name: 'Tandartspraktijk De Kies', email: 'balie@dekies.example' },
    bodyText: 'Bijgaand de nota voor de controle.',
    receivedAt: new Date('2026-03-12T08:00:00Z'),
  });
  h.provider(home.id).deliver({
    subject: 'Etentje zaterdag?',
    bodyText: 'Neem jij de factuur van de catering mee?',
    receivedAt: new Date('2026-03-20T08:00:00Z'),
  });
  h.provider(work.id).deliver({
    subject: 'Factuur 2026-031',
    from: { name: 'Studio Vos', email: 'admin@vos.example' },
    receivedAt: new Date('2026-02-02T08:00:00Z'),
  });
  h.provider(evas.id).deliver({ subject: 'Factuur tandarts Eva' });
  for (const box of [home, work, evas]) await h.mail.sync(box.id);
  return { ...h, token: h.key(gideon.id, ['read']) };
}

const subjects = async (res: Response) =>
  searchResponse.parse(await res.json()).results.map((m) => m.subject);

describe('word search', () => {
  it('finds mail in every mailbox the key sees, never someone else’s', async () => {
    const s = await setup();
    const res = await s.call(s.token, '/api/search?q=factuur');
    expect(await subjects(res)).toEqual([
      'Etentje zaterdag?',
      'Factuur 2026-031',
    ]);
  });

  it('needs every word, in subject, sender or body', async () => {
    const s = await setup();
    expect(
      await subjects(await s.call(s.token, '/api/search?q=nota%20kies')),
    ).toEqual(['Uw nota van maart']);
    expect(
      await subjects(await s.call(s.token, '/api/search?q=nota%20vos')),
    ).toEqual([]);
  });

  it('takes LIKE wildcards literally', async () => {
    const s = await setup();
    expect(await subjects(await s.call(s.token, '/api/search?q=%25'))).toEqual(
      [],
    );
  });
});

describe('search by meaning', () => {
  const ask = (s: Awaited<ReturnType<typeof setup>>, question: string) =>
    s.call(s.token, '/api/search/ai', {
      method: 'POST',
      body: JSON.stringify({ question }),
    });

  it('runs the bot’s plan and ranks mail that matches more of it first', async () => {
    const s = await setup();
    s.decisions.push({
      groups: [
        ['factuur', 'nota'],
        ['tandarts', 'kies'],
      ],
      from: null,
      after: '2026-03-01',
      before: '2026-04-01',
      folder: null,
      roles: null,
      unreadOnly: false,
      hasAttachments: false,
      explanation: 'Facturen van de tandarts, maart 2026',
    });
    const res = await ask(s, 'de rekening van de tandarts in maart');
    const body = searchResponse.parse(await res.json());
    expect(body.explanation).toBe('Facturen van de tandarts, maart 2026');
    expect(body.results.map((m) => m.subject)).toEqual([
      'Uw nota van maart',
      'Etentje zaterdag?',
    ]);
  });

  it('gives the bot only the question and the mailboxes, never mail', async () => {
    const s = await setup();
    s.decisions.push({
      groups: [['factuur']],
      from: null,
      after: null,
      before: null,
      folder: null,
      roles: ['work'],
      unreadOnly: false,
      hasAttachments: false,
      explanation: 'Facturen in je zakelijke mail',
    });
    const res = await ask(s, 'facturen in mijn zakelijke mail');
    expect(await subjects(res)).toEqual(['Factuur 2026-031']);
    const prompt = s.agentRequests[0]!.prompt;
    expect(prompt).toContain('facturen in mijn zakelijke mail');
    expect(prompt).toContain('gideon@studio.example (work');
    expect(prompt).not.toContain('Etentje');
    expect(prompt).not.toContain('eva@example.com');
  });
});
