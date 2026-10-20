import { searchResponse } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const provider = h.provider(home.id);
  provider.pageSize = 2;
  // Mail from before Hedwig, which the first sync never brings in.
  provider.keep({
    subject: 'HelloTV Black Friday',
    bodyText: 'Een LG TV met korting.',
    receivedAt: new Date('2024-11-30T08:00:00Z'),
  });
  provider.keep({
    subject: 'Bestelling verzonden',
    folder: 'archive',
    receivedAt: new Date('2025-04-28T08:00:00Z'),
  });
  provider.keep({
    subject: 'Re: de tv ophangen',
    folder: 'sent',
    unread: false,
    receivedAt: new Date('2025-06-01T08:00:00Z'),
  });
  provider.deliver({ subject: 'Nieuw vandaag' });
  await h.mail.sync(home.id);
  return { ...h, home, provider, token: h.key(gideon.id, ['read']) };
}

type Setup = Awaited<ReturnType<typeof setup>>;

const backfillAll = async (s: Setup) => {
  let pages = 0;
  while (await s.mail.backfill(s.home.id)) pages++;
  return pages + 1;
};

const search = async (s: Setup, q: string) =>
  searchResponse
    .parse(await (await s.call(s.token, `/api/search?q=${q}`)).json())
    .results.map((m) => m.subject);

describe('bringing in the archive', () => {
  it('fetches older mail in every folder, page by page, so search finds it', async () => {
    const s = await setup();
    expect(await search(s, 'tv')).toEqual([]);

    expect(await backfillAll(s)).toBe(2);
    expect(await search(s, 'tv')).toEqual([
      'Re: de tv ophangen',
      'HelloTV Black Friday',
    ]);
    expect(await search(s, 'bestelling')).toEqual(['Bestelling verzonden']);
  });

  it('stops asking the provider once the archive is in', async () => {
    const s = await setup();
    await backfillAll(s);
    const calls = s.provider.backfillCalls;
    expect(await s.mail.backfill(s.home.id)).toBe(false);
    expect(s.provider.backfillCalls).toBe(calls);
  });

  it('never sorts old mail, announces it or doubles mail sync already has', async () => {
    const s = await setup();
    const events: unknown[] = [];
    s.events.subscribe((e) => events.push(e.data));
    s.arrived.length = 0;
    s.decisions.push({
      action: { kind: 'keep' },
      reason: 'Nieuw.',
      unsure: false,
    });

    await backfillAll(s);
    await s.triage.retryUntriaged(new Date(0));

    expect(s.arrived).toEqual([]);
    expect(events).toEqual([]);
    // Only the new mail, which sync brought in, is up for sorting.
    expect(s.agentRequests).toHaveLength(1);
    expect(s.agentRequests[0]!.prompt).toContain('Nieuw vandaag');
    expect(await search(s, 'nieuw')).toEqual(['Nieuw vandaag']);
  });
});
