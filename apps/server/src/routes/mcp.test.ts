import type { Right } from '@burrow/contracts';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { messages } from '../db/schema';
import { testHousehold } from '../testing';

async function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  h.provider(home.id).deliver({
    subject: 'Offerte poorten',
    bodyText: 'Graag akkoord voor vrijdag',
  });
  h.provider(evas.id).deliver({ subject: 'Eva private' });
  await h.mail.sync(home.id);
  await h.mail.sync(evas.id);
  return { ...h, gideon, eva, home, evas };
}

type Setup = Awaited<ReturnType<typeof setup>>;

// A real MCP client talking to the app in-process.
async function connect(s: Setup, rights: Right[], factsOnly = false) {
  const token = s.key(s.gideon.id, rights, null, factsOnly);
  const client = new Client({ name: 'test', version: '1' });
  await client.connect(
    new StreamableHTTPClientTransport(new URL('http://burrow.test/api/mcp'), {
      requestInit: { headers: { authorization: `Bearer ${token}` } },
      fetch: async (url, init) => s.app.request(String(url), init),
    }),
  );
  return client;
}

const json = (result: unknown) =>
  JSON.parse((result as { content: { text: string }[] }).content[0]!.text);

describe('MCP', () => {
  it('refuses a request without a valid key', async () => {
    const s = await setup();
    const res = await s.app.request('/api/mcp', { method: 'POST', body: '{}' });
    expect(res.status).toBe(401);
  });

  it('offers only the tools the key has rights for, and never a send tool', async () => {
    const s = await setup();
    const reader = await connect(s, ['read']);
    expect((await reader.listTools()).tools.map((t) => t.name).sort()).toEqual([
      'get_instructions',
      'get_message',
      'get_recording',
      'get_settings',
      'list_mailboxes',
      'list_outings',
      'list_recording_labels',
      'list_recordings',
      'list_routines',
      'list_tasks',
      'list_watchlist',
      'search_messages',
      'search_recordings',
      'search_titles',
    ]);
    const full = await connect(s, ['read', 'organize', 'draft', 'send']);
    const names = (await full.listTools()).tools.map((t) => t.name);
    expect(names).toContain('create_draft');
    expect(names).toContain('label_recording');
    expect(names.some((n) => /send/.test(n))).toBe(false);
    const facts = await connect(s, ['read'], true);
    const factTools = (await facts.listTools()).tools.map((t) => t.name);
    expect(factTools).toContain('search_messages');
    expect(factTools).not.toContain('get_message');
  });

  it('lets an agent add an outing the whole household sees, without its tickets', async () => {
    const s = await setup();
    const agent = await connect(s, ['read', 'organize']);
    const added = json(
      await agent.callTool({
        name: 'add_outing',
        arguments: {
          title: 'Etentje bij Sanne',
          startsAt: '2026-10-24T16:00:00.000Z',
        },
      }),
    );
    expect(added).toMatchObject({
      title: 'Etentje bij Sanne',
      createdBy: { name: 'Gideon' },
    });
    const evaKey = s.key(s.eva.id, ['read']);
    const res = await s.call(evaKey, '/api/outings');
    expect((await res.json()) as unknown[]).toHaveLength(1);
    const reader = await connect(s, ['read']);
    expect((await reader.listTools()).tools.map((t) => t.name)).not.toContain(
      'add_outing',
    );
  });

  it('searches and reads only the key’s mailboxes', async () => {
    const s = await setup();
    const client = await connect(s, ['read']);
    const found = json(
      await client.callTool({
        name: 'search_messages',
        arguments: { query: 'akkoord' },
      }),
    );
    expect(found.map((m: { subject: string }) => m.subject)).toEqual([
      'Offerte poorten',
    ]);
    expect(
      json(await client.callTool({ name: 'search_messages', arguments: {} })),
    ).toHaveLength(1);

    const [evaMessage] = s.db
      .select()
      .from(messages)
      .where(eq(messages.mailboxId, s.evas.id))
      .all();
    const denied = await client.callTool({
      name: 'get_message',
      arguments: { id: evaMessage!.id },
    });
    expect(denied.isError).toBe(true);
  });

  it('organizes at the provider and prepares drafts that a person sends', async () => {
    const s = await setup();
    const client = await connect(s, ['read', 'organize', 'draft']);
    const [message] = json(
      await client.callTool({
        name: 'search_messages',
        arguments: { query: 'Offerte' },
      }),
    );

    await client.callTool({
      name: 'organize_message',
      arguments: { id: message.id, ops: ['flag'], addLabels: ['Offerte'] },
    });
    expect(s.provider(s.home.id).applied[0]?.ops).toEqual([
      { op: 'flag' },
      { op: 'addLabel', label: 'Offerte' },
    ]);

    const draft = json(
      await client.callTool({
        name: 'create_draft',
        arguments: {
          mailboxId: s.home.id,
          to: [{ email: 'joris@example.nl' }],
          subject: 'Re: Offerte',
          body: 'Akkoord',
          inReplyTo: message.id,
        },
      }),
    );
    expect(draft).toMatchObject({
      subject: 'Re: Offerte',
      createdBy: 'test key',
    });
    expect(s.provider(s.home.id).sent).toEqual([]);
  });
});
