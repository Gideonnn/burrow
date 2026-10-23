import { describe, expect, it } from 'vitest';
import { type JmapEmail, JmapClient } from './jmap';

const MAILBOXES = [
  { id: 'mb-inbox', role: 'inbox' },
  { id: 'mb-junk', role: 'junk' },
  { id: 'mb-archive', role: 'archive' },
  { id: 'mb-trash', role: 'trash' },
  { id: 'mb-drafts', role: 'drafts' },
  { id: 'mb-sent', role: 'sent' },
  { id: 'mb-custom', role: null },
];

function email(
  id: string,
  mailbox: string,
  extra: Partial<JmapEmail> = {},
): JmapEmail {
  return {
    id,
    threadId: `t-${id}`,
    mailboxIds: { [mailbox]: true },
    keywords: {},
    from: [{ name: 'Marieke', email: 'marieke@example.nl' }],
    to: [{ name: null, email: 'owner@example.com' }],
    subject: `Subject ${id}`,
    preview: 'Zin in eten?',
    receivedAt: '2026-10-19T09:41:00Z',
    hasAttachment: false,
    messageId: [`${id}@example.nl`],
    textBody: [{ partId: '1', type: 'text/plain' }],
    htmlBody: [{ partId: '2', type: 'text/html' }],
    bodyValues: {
      '1': { value: 'Zin in eten?' },
      '2': { value: '<p>Zin in eten?</p>' },
    },
    'header:List-Unsubscribe:asText': null,
    ...extra,
  };
}

// In-memory JMAP server: session, Mailbox/get, Email/query+get with back
// references, Email/changes, Email/set update and create, Identity/get and
// EmailSubmission/set.
function fakeJmap() {
  const emails = new Map<string, JmapEmail>();
  const log: {
    state: number;
    id: string;
    kind: 'created' | 'updated' | 'destroyed';
  }[] = [];
  let state = 1;
  let oldest = 1;
  const requests: [string, Record<string, any>, string][][] = [];

  const handle = (
    name: string,
    args: Record<string, any>,
    results: Map<string, any>,
  ) => {
    switch (name) {
      case 'Mailbox/get':
        return { list: MAILBOXES };
      case 'Email/query': {
        const { inMailbox, inMailboxOtherThan } = args.filter ?? {};
        const ids = [...emails.values()]
          .filter((e) =>
            inMailbox
              ? e.mailboxIds[inMailbox]
              : Object.keys(e.mailboxIds).some(
                  (m) => !inMailboxOtherThan?.includes(m),
                ),
          )
          .sort((a, b) => b.receivedAt.localeCompare(a.receivedAt))
          .map((e) => e.id);
        const position = args.position ?? 0;
        return { ids: ids.slice(position, position + (args.limit ?? 100)) };
      }
      case 'Email/get': {
        const ids: string[] =
          args.ids ?? results.get(args['#ids'].resultOf).ids;
        return {
          state: String(state),
          list: ids.flatMap((id) => (emails.has(id) ? [emails.get(id)] : [])),
          notFound: ids.filter((id) => !emails.has(id)),
        };
      }
      case 'Email/changes': {
        const since = Number(args.sinceState);
        if (since < oldest) return { error: 'cannotCalculateChanges' };
        const entries = log.filter((l) => l.state > since);
        const pick = (k: string) =>
          entries.filter((e) => e.kind === k).map((e) => e.id);
        return {
          created: pick('created'),
          updated: pick('updated'),
          destroyed: pick('destroyed'),
          newState: String(state),
          hasMoreChanges: false,
        };
      }
      case 'Email/set':
        if (args.update) {
          for (const [id, patch] of Object.entries(
            args.update as Record<string, Record<string, unknown>>,
          )) {
            const e = emails.get(id)!;
            for (const [path, value] of Object.entries(patch)) {
              if (path === 'mailboxIds')
                e.mailboxIds = value as Record<string, true>;
              else {
                const [field, key] = path.split('/') as [
                  'keywords' | 'mailboxIds',
                  string,
                ];
                if (value === null) delete e[field][key];
                else e[field][key] = true;
              }
            }
          }
          return { updated: args.update };
        }
        return { created: { draft: { id: 'new-1' } } };
      case 'Identity/get':
        return { list: [{ id: 'id-1', email: 'owner@example.com' }] };
      case 'EmailSubmission/set':
        return { created: { s: { id: 'sub-1' } } };
    }
    return { error: 'unknownMethod' };
  };

  const fetchFn = async (
    input: string | URL | Request,
    init: RequestInit = {},
  ) => {
    const url = String(input);
    if (url.endsWith('/session')) {
      return new Response(
        JSON.stringify({
          apiUrl: 'https://jmap.example/api',
          username: 'owner@example.com',
          primaryAccounts: { 'urn:ietf:params:jmap:mail': 'acc-1' },
        }),
      );
    }
    const body = JSON.parse(String(init.body));
    requests.push(body.methodCalls);
    const results = new Map<string, any>();
    const methodResponses = body.methodCalls.map(
      ([name, args, tag]: [string, any, string]) => {
        const result = handle(name, args, results);
        if (result.error) return ['error', { type: result.error }, tag];
        results.set(tag, result);
        return [name, result, tag];
      },
    );
    return new Response(JSON.stringify({ methodResponses }));
  };

  return {
    requests,
    fetchFn: fetchFn as typeof fetch,
    deliver(e: JmapEmail) {
      emails.set(e.id, e);
      log.push({ state: ++state, id: e.id, kind: 'created' });
    },
    update(id: string, change: Partial<JmapEmail>) {
      Object.assign(emails.get(id)!, change);
      log.push({ state: ++state, id, kind: 'updated' });
    },
    destroy(id: string) {
      emails.delete(id);
      log.push({ state: ++state, id, kind: 'destroyed' });
    },
    forget() {
      oldest = state + 1;
    },
    email: (id: string) => emails.get(id)!,
  };
}

const client = (api: ReturnType<typeof fakeJmap>) =>
  new JmapClient('fmu1-token', api.fetchFn, 'https://jmap.example/session');

describe('JmapClient', () => {
  it('parses an email with keywords as labels and bodies from body values', async () => {
    const api = fakeJmap();
    api.deliver(
      email('a', 'mb-inbox', {
        keywords: { $flagged: true, Bon: true },
        replyTo: [{ name: null, email: 'eten@example.nl' }],
      }),
    );
    const { upserts } = await client(api).sync(null);
    expect(upserts[0]).toMatchObject({
      providerId: 'a',
      folder: 'inbox',
      unread: true,
      flagged: true,
      labels: ['Bon'],
      to: [{ email: 'owner@example.com' }],
      replyTo: [{ email: 'eten@example.nl' }],
      bodyText: 'Zin in eten?',
      bodyHtml: '<p>Zin in eten?</p>',
      headers: { messageId: '<a@example.nl>' },
    });
  });

  it('follows changes from the state, and starts over when the server cannot', async () => {
    const api = fakeJmap();
    const c = client(api);
    api.deliver(email('a', 'mb-inbox'));
    const first = await c.sync(null);
    api.deliver(email('b', 'mb-inbox'));
    api.update('a', { mailboxIds: { 'mb-junk': true } });
    api.destroy('b');
    const next = await c.sync(first.cursor);
    expect(next.upserts.map((m) => [m.providerId, m.folder])).toEqual([
      ['a', 'spam'],
    ]);
    expect(next.removed).toEqual(['b']);

    api.forget();
    api.update('a', { mailboxIds: { 'mb-inbox': true } });
    const reset = await c.sync(next.cursor);
    expect(reset.upserts.map((m) => m.providerId)).toEqual(['a']);
  });

  it('backfills every mailbox but junk, trash and drafts, newest first, page by page', async () => {
    const api = fakeJmap();
    const c = new JmapClient(
      'fmu1-token',
      api.fetchFn,
      'https://jmap.example/session',
      2,
    );
    const at = (day: number) => ({ receivedAt: `2025-01-0${day}T08:00:00Z` });
    api.deliver(email('custom', 'mb-custom', at(1)));
    api.deliver(email('sent', 'mb-sent', at(2)));
    api.deliver(email('junk', 'mb-junk', at(3)));
    api.deliver(email('draft', 'mb-drafts', at(4)));
    api.deliver(email('old', 'mb-archive', at(5)));
    api.deliver(email('new', 'mb-inbox', at(6)));

    const pages: [string, string][][] = [];
    let page: string | null = null;
    do {
      const result = await c.backfill(page);
      pages.push(result.messages.map((m) => [m.providerId, m.folder]));
      page = result.next;
    } while (page);
    expect(pages).toEqual([
      [
        ['new', 'inbox'],
        ['old', 'archive'],
      ],
      [
        ['sent', 'sent'],
        ['custom', 'archive'],
      ],
      [],
    ]);
  });

  it('applies operations as one Email/set with keyword and mailbox patches', async () => {
    const api = fakeJmap();
    api.deliver(email('a', 'mb-inbox'));
    await client(api).apply('a', [
      { op: 'moveToSpam' },
      { op: 'markRead' },
      { op: 'addLabel', label: 'Spam check' },
    ]);
    expect(api.email('a').mailboxIds).toEqual({ 'mb-junk': true });
    expect(api.email('a').keywords).toEqual({ $seen: true, Spam_check: true });
  });

  it('sends a reply as a draft plus a submission that files it under Sent', async () => {
    const api = fakeJmap();
    await client(api).send({
      from: { email: 'owner@example.com' },
      to: [{ email: 'marieke@example.nl' }],
      cc: [],
      subject: 'Re: Etentje',
      body: 'Gezellig!',
      replyTo: {
        providerId: 'a',
        threadId: 't-a',
        headers: { messageId: '<a@example.nl>' },
      },
    });
    const calls = api.requests.at(-1)!;
    const [, create] = calls[0]!;
    const [, submit] = calls[1]!;
    expect(create.create.draft).toMatchObject({
      inReplyTo: ['a@example.nl'],
      subject: 'Re: Etentje',
    });
    expect(submit.create.s).toEqual({ identityId: 'id-1', emailId: '#draft' });
    expect(submit.onSuccessUpdateEmail['#s']).toMatchObject({
      'mailboxIds/mb-sent': true,
    });
  });

  it('knows its address from the session', async () => {
    expect(await client(fakeJmap()).address()).toBe('owner@example.com');
  });
});

// Email/get with the attachments property, and the session's download
// template, in the shapes Fastmail answers with.
const JMAP_ATTACHMENTS = [
  {
    partId: '3',
    blobId: 'G6f1c2a7d9e',
    size: 9,
    name: 'offerte 2026.pdf',
    type: 'application/pdf',
    disposition: 'attachment',
    cid: null,
  },
  {
    partId: '4',
    blobId: 'G0b8e44f1aa',
    size: 4,
    name: 'logo.png',
    type: 'image/png',
    disposition: 'inline',
    cid: 'logo@example.nl',
  },
];

function jmapAttachments() {
  const downloads: string[] = [];
  const calls: [string, Record<string, any>, string][] = [];
  const fetchFn = async (
    input: string | URL | Request,
    init: RequestInit = {},
  ) => {
    const url = String(input);
    if (url.endsWith('/session')) {
      return Response.json({
        apiUrl: 'https://jmap.example/api',
        downloadUrl:
          'https://jmap.example/download/{accountId}/{blobId}/{name}?type={type}',
        username: 'owner@example.com',
        primaryAccounts: { 'urn:ietf:params:jmap:mail': 'acc-1' },
      });
    }
    if (url.startsWith('https://jmap.example/download/')) {
      downloads.push(url);
      return new Response('%PDF-1.4!');
    }
    const body = JSON.parse(String(init.body));
    calls.push(...body.methodCalls);
    const [, args, tag] = body.methodCalls[0];
    const found = args.ids.includes('e1');
    return Response.json({
      methodResponses: [
        [
          'Email/get',
          {
            state: '9',
            list: found ? [{ id: 'e1', attachments: JMAP_ATTACHMENTS }] : [],
            notFound: found ? [] : args.ids,
          },
          tag,
        ],
      ],
    });
  };
  return {
    client: new JmapClient(
      'fmu1-token',
      fetchFn as typeof fetch,
      'https://jmap.example/session',
    ),
    downloads,
    calls,
  };
}

describe('JmapClient attachments', () => {
  it('lists attachments by part, inline images included', async () => {
    const { client, calls } = jmapAttachments();
    expect(await client.attachments('e1')).toEqual([
      {
        id: '3',
        name: 'offerte 2026.pdf',
        contentType: 'application/pdf',
        size: 9,
        inline: false,
      },
      {
        id: '4',
        name: 'logo.png',
        contentType: 'image/png',
        size: 4,
        inline: true,
      },
    ]);
    expect(calls[0]?.[1].properties).toEqual(['id', 'attachments']);
  });

  it('downloads the blob through the session download template', async () => {
    const { client, downloads } = jmapAttachments();
    const data = await client.attachment('e1', '3');
    expect(Buffer.from(data).toString()).toBe('%PDF-1.4!');
    expect(downloads).toEqual([
      'https://jmap.example/download/acc-1/G6f1c2a7d9e/offerte%202026.pdf?type=application%2Fpdf',
    ]);
  });

  it('refuses a part that is not an attachment of the email', async () => {
    const { client } = jmapAttachments();
    await expect(client.attachment('e1', '1')).rejects.toThrow();
    await expect(client.attachments('gone')).rejects.toThrow();
  });
});
