import { messageInsights } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  h.provider(home.id).deliver({
    subject: 'Etentje zaterdag?',
    bodyText: 'Kom je eten? Neem jij het toetje mee?',
  });
  h.provider(evas.id).deliver({ subject: 'Private' });
  const [mine] = await h.mail.sync(home.id);
  const [hers] = await h.mail.sync(evas.id);
  return { ...h, mine: mine!, hers: hers!, token: h.key(gideon.id, ['read']) };
}

const suggestion = {
  summary: null,
  replies: [
    {
      label: 'Ja, gezellig',
      body: 'Hoi Marieke,\n\nGezellig, ik neem het toetje mee.\n\nGroet',
    },
    {
      label: 'Lukt niet',
      body: 'Hoi Marieke,\n\nZaterdag lukt helaas niet.\n\nGroet',
    },
  ],
};

describe('message insights', () => {
  it('asks the bot once with only the reply skill, and serves the cached answer after', async () => {
    const s = await setup();
    s.decisions.push(suggestion);
    const first = messageInsights.parse(
      await (await s.call(s.token, `/api/messages/${s.mine}/insights`)).json(),
    );
    const again = messageInsights.parse(
      await (await s.call(s.token, `/api/messages/${s.mine}/insights`)).json(),
    );
    expect(first.replies.map((r) => r.label)).toEqual([
      'Ja, gezellig',
      'Lukt niet',
    ]);
    expect(again).toEqual(first);
    expect(s.agentRequests).toHaveLength(1);
    expect(s.agentRequests[0]?.system).toContain('Suggest replies.');
    expect(s.agentRequests[0]?.system).not.toContain('Sort it.');
  });

  it('shares one run between concurrent requests', async () => {
    const s = await setup();
    s.decisions.push(suggestion);
    await Promise.all([s.insights.get(s.mine), s.insights.get(s.mine)]);
    expect(s.agentRequests).toHaveLength(1);
  });

  it('answers 404 for another person’s message and 502 when the bot fails', async () => {
    const s = await setup();
    expect(
      (await s.call(s.token, `/api/messages/${s.hers}/insights`)).status,
    ).toBe(404);
    s.decisions.push(new Error('logged out'));
    expect(
      (await s.call(s.token, `/api/messages/${s.mine}/insights`)).status,
    ).toBe(502);
  });

  it('rejects an answer with more than three replies', async () => {
    const s = await setup();
    s.decisions.push({
      summary: null,
      replies: Array(4).fill(suggestion.replies[0]),
    });
    expect(
      (await s.call(s.token, `/api/messages/${s.mine}/insights`)).status,
    ).toBe(502);
  });
});
