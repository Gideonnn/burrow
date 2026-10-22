import { describe, expect, it } from 'vitest';
import { GraphClient, type GraphMessage } from './graph';

const FOLDER_IDS: Record<string, string> = {
  inbox: 'F-inbox',
  junkemail: 'F-junk',
  archive: 'F-archive',
  deleteditems: 'F-deleted',
  sentitems: 'F-sent',
};

function graphMessage(
  id: string,
  folder: string,
  extra: Partial<GraphMessage> = {},
): GraphMessage {
  return {
    id,
    conversationId: `c-${id}`,
    subject: `Subject ${id}`,
    bodyPreview: 'Preview',
    body: { contentType: 'html', content: '<p>Beste Gideon,</p><p>Groet</p>' },
    from: { emailAddress: { name: 'Joris', address: 'joris@example.nl' } },
    toRecipients: [
      {
        emailAddress: {
          name: 'gideon@example.com',
          address: 'gideon@example.com',
        },
      },
    ],
    receivedDateTime: '2026-10-19T08:15:00Z',
    isRead: false,
    flag: { flagStatus: 'notFlagged' },
    categories: [],
    hasAttachments: false,
    parentFolderId: FOLDER_IDS[folder]!,
    internetMessageId: `<${id}@example.nl>`,
    internetMessageHeaders: [
      { name: 'Authentication-Results', value: 'dkim=pass' },
    ],
    ...extra,
  };
}

// In-memory Graph: delta per folder with removal markers, single message
// reads, PATCH, move, reply and sendMail.
function fakeGraph() {
  const messages = new Map<string, GraphMessage>();
  const changes: {
    seq: number;
    folder: string;
    id: string;
    removed: boolean;
  }[] = [];
  let seq = 0;
  const calls: {
    method: string;
    path: string;
    body?: unknown;
    prefer?: string;
  }[] = [];

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status });

  const fetchFn = async (
    input: string | URL | Request,
    init: RequestInit = {},
  ) => {
    const url = new URL(String(input));
    const path = decodeURIComponent(url.pathname.replace('/v1.0/me', ''));
    const method = init.method ?? 'GET';
    const headers = init.headers as Record<string, string>;
    calls.push({
      method,
      path,
      body: init.body ? JSON.parse(String(init.body)) : undefined,
      prefer: headers.Prefer,
    });
    if (path === '')
      return json({ mail: 'gideon@example.com', userPrincipalName: 'x' });
    const folder = /^\/mailFolders\/(\w+)$/.exec(path);
    if (folder)
      return FOLDER_IDS[folder[1]!]
        ? json({ id: FOLDER_IDS[folder[1]!] })
        : json({}, 404);
    const delta = /^\/mailFolders\/(\w+)\/messages\/delta$/.exec(path);
    if (delta) {
      const since = Number(url.searchParams.get('since') ?? 0);
      const items = changes
        .filter((c) => c.folder === delta[1] && c.seq > since)
        .map((c) =>
          c.removed
            ? { id: c.id, '@removed': { reason: 'changed' } }
            : { id: c.id },
        );
      return json({
        value: items,
        '@odata.deltaLink': `https://graph.microsoft.com/v1.0/me/mailFolders/${delta[1]}/messages/delta?since=${seq}`,
      });
    }
    if (path === '/messages' && method === 'GET') {
      const all = [...messages.values()].sort((a, b) =>
        b.receivedDateTime.localeCompare(a.receivedDateTime),
      );
      const skip = Number(url.searchParams.get('$skip') ?? 0);
      const top = Number(url.searchParams.get('$top'));
      const next = new URL(url);
      next.searchParams.set('$skip', String(skip + top));
      return json({
        value: all.slice(skip, skip + top),
        ...(skip + top < all.length ? { '@odata.nextLink': String(next) } : {}),
      });
    }
    const one = /^\/messages\/([^/]+)$/.exec(path);
    if (one && method === 'GET') {
      const m = messages.get(one[1]!);
      return m ? json(m) : json({ error: 'gone' }, 404);
    }
    if (one && method === 'PATCH') {
      Object.assign(messages.get(one[1]!)!, JSON.parse(String(init.body)));
      return json({});
    }
    const move = /^\/messages\/([^/]+)\/move$/.exec(path);
    if (move) {
      const m = messages.get(move[1]!)!;
      const dest = JSON.parse(String(init.body)).destinationId as string;
      m.parentFolderId = FOLDER_IDS[dest]!;
      return json(m);
    }
    if (path.endsWith('/reply') || path === '/sendMail')
      return new Response(null, { status: 202 });
    return json({ error: `unhandled ${method} ${path}` }, 500);
  };

  const folderOf = (m: GraphMessage) =>
    Object.keys(FOLDER_IDS).find((k) => FOLDER_IDS[k] === m.parentFolderId)!;

  return {
    calls,
    fetchFn: fetchFn as typeof fetch,
    session: { accessToken: async () => 'token' },
    deliver(m: GraphMessage) {
      messages.set(m.id, m);
      changes.push({
        seq: ++seq,
        folder: folderOf(m),
        id: m.id,
        removed: false,
      });
    },
    move(id: string, folder: string) {
      const m = messages.get(id)!;
      changes.push({ seq: ++seq, folder: folderOf(m), id, removed: true });
      m.parentFolderId = FOLDER_IDS[folder]!;
      if (folder === 'inbox' || folder === 'junkemail')
        changes.push({ seq: ++seq, folder, id, removed: false });
    },
    delete(id: string) {
      const m = messages.get(id)!;
      messages.delete(id);
      changes.push({ seq: ++seq, folder: folderOf(m), id, removed: true });
    },
  };
}

describe('GraphClient', () => {
  it('parses a message, deriving plain text from the HTML body', async () => {
    const api = fakeGraph();
    api.deliver(
      graphMessage('a', 'inbox', {
        categories: ['Offerte'],
        flag: { flagStatus: 'flagged' },
      }),
    );
    const { upserts } = await new GraphClient(api.session, api.fetchFn).sync(
      null,
    );
    expect(upserts[0]).toMatchObject({
      providerId: 'a',
      threadId: 'c-a',
      from: { name: 'Joris', email: 'joris@example.nl' },
      to: [{ email: 'gideon@example.com' }],
      folder: 'inbox',
      unread: true,
      flagged: true,
      labels: ['Offerte'],
      bodyText: 'Beste Gideon,\nGroet',
      headers: {
        messageId: '<a@example.nl>',
        authenticationResults: 'dkim=pass',
      },
    });
  });

  it('backfills every folder but junk and trash, newest first, page by page', async () => {
    const api = fakeGraph();
    const client = new GraphClient(api.session, api.fetchFn, undefined, 2);
    const at = (day: number) => ({
      receivedDateTime: `2025-01-0${day}T08:00:00Z`,
    });
    api.deliver(graphMessage('old', 'archive', at(1)));
    api.deliver(graphMessage('sent', 'sentitems', at(2)));
    api.deliver(graphMessage('junk', 'junkemail', at(3)));
    api.deliver(graphMessage('draft', 'inbox', { ...at(4), isDraft: true }));
    api.deliver(graphMessage('new', 'inbox', at(5)));

    const pages: [string, string][][] = [];
    let page: string | null = null;
    do {
      const result = await client.backfill(page);
      pages.push(result.messages.map((m) => [m.providerId, m.folder]));
      page = result.next;
    } while (page);
    expect(pages).toEqual([
      [['new', 'inbox']],
      [['sent', 'sent']],
      [['old', 'archive']],
    ]);
    const list = api.calls.find((c) => c.path === '/messages');
    expect(list?.prefer).toContain('IdType="ImmutableId"');
  });

  it('asks for immutable ids so moved mail keeps its id', async () => {
    const api = fakeGraph();
    await new GraphClient(
      api.session,
      api.fetchFn,
      () => new Date('2026-10-19T00:00:00Z'),
    ).sync(null);
    const delta = api.calls.find((c) => c.path.endsWith('/delta'));
    expect(delta?.prefer).toContain('IdType="ImmutableId"');
  });

  it('tells a moved message from a deleted one', async () => {
    const api = fakeGraph();
    const client = new GraphClient(api.session, api.fetchFn);
    api.deliver(graphMessage('a', 'inbox'));
    api.deliver(graphMessage('b', 'inbox'));
    const first = await client.sync(null);

    api.move('a', 'archive');
    api.delete('b');
    const next = await client.sync(first.cursor);
    expect(next.upserts.map((m) => [m.providerId, m.folder])).toEqual([
      ['a', 'archive'],
    ]);
    expect(next.removed).toEqual(['b']);
  });

  it('patches flags and read state, then moves, keeping existing categories', async () => {
    const api = fakeGraph();
    api.deliver(graphMessage('a', 'inbox', { categories: ['Offerte'] }));
    await new GraphClient(api.session, api.fetchFn).apply('a', [
      { op: 'moveToSpam' },
      { op: 'markRead' },
      { op: 'addLabel', label: 'Spam?' },
    ]);
    const writes = api.calls.filter((c) => c.method !== 'GET');
    expect(writes.map((c) => c.method)).toEqual(['PATCH', 'POST']);
    expect(writes[0]?.body).toEqual({
      isRead: true,
      categories: ['Offerte', 'Spam?'],
    });
    expect(writes[1]?.body).toEqual({ destinationId: 'junkemail' });
  });

  it('replies through the reply endpoint to keep the conversation', async () => {
    const api = fakeGraph();
    await new GraphClient(api.session, api.fetchFn).send({
      from: { email: 'gideon@example.com' },
      to: [{ email: 'joris@example.nl' }],
      cc: [],
      subject: 'Re: Offerte',
      body: 'Akkoord',
      replyTo: { providerId: 'a', threadId: 'c-a', headers: {} },
    });
    const reply = api.calls.find((c) => c.path === '/messages/a/reply');
    expect(reply?.body).toMatchObject({ comment: 'Akkoord' });
  });
});

// The shapes of GET /me/messages/{id}/attachments and of one attachment,
// as Graph answers them. Ids are URL-safe base64 with padding.
const PDF_ID = 'AAMkADA1-attachment_1=';
const LOGO_ID = 'AAMkADA1-attachment_2=';
const GRAPH_ATTACHMENTS = [
  {
    '@odata.type': '#microsoft.graph.fileAttachment',
    '@odata.mediaContentType': 'application/pdf',
    id: PDF_ID,
    name: 'offerte.pdf',
    contentType: 'application/pdf',
    size: 9,
    isInline: false,
  },
  {
    '@odata.type': '#microsoft.graph.fileAttachment',
    id: LOGO_ID,
    name: 'image001.png',
    contentType: 'image/png',
    size: 4,
    isInline: true,
  },
  {
    '@odata.type': '#microsoft.graph.itemAttachment',
    id: 'AAMkADA1-attachment_3=',
    name: 'Doorgestuurd: planning',
    contentType: null,
    size: 18_000,
    isInline: false,
  },
  {
    '@odata.type': '#microsoft.graph.referenceAttachment',
    id: 'AAMkADA1-attachment_4=',
    name: 'Begroting.xlsx',
    contentType: null,
    size: 600,
    isInline: false,
  },
];

function graphAttachments() {
  const paths: string[] = [];
  const fetchFn = async (input: string | URL | Request) => {
    const url = new URL(String(input));
    const path = decodeURIComponent(url.pathname.replace('/v1.0/me', ''));
    paths.push(url.pathname + url.search);
    if (path === '/messages/m1/attachments') {
      return Response.json({ value: GRAPH_ATTACHMENTS });
    }
    if (path === `/messages/m1/attachments/${PDF_ID}`) {
      return Response.json({
        ...GRAPH_ATTACHMENTS[0],
        contentBytes: Buffer.from('%PDF-1.4!').toString('base64'),
      });
    }
    return Response.json(
      { error: { code: 'ErrorItemNotFound' } },
      { status: 404 },
    );
  };
  return {
    client: new GraphClient(
      { accessToken: async () => 'token' },
      fetchFn as typeof fetch,
    ),
    paths,
  };
}

describe('GraphClient attachments', () => {
  it('lists file attachments, inline images included, and leaves out items and links', async () => {
    const { client } = graphAttachments();
    expect(await client.attachments('m1')).toEqual([
      {
        id: PDF_ID,
        name: 'offerte.pdf',
        contentType: 'application/pdf',
        size: 9,
        inline: false,
      },
      {
        id: LOGO_ID,
        name: 'image001.png',
        contentType: 'image/png',
        size: 4,
        inline: true,
      },
    ]);
  });

  it('downloads the content bytes of one file attachment', async () => {
    const { client, paths } = graphAttachments();
    const data = await client.attachment('m1', PDF_ID);
    expect(Buffer.from(data).toString()).toBe('%PDF-1.4!');
    expect(paths.at(-1)).toContain(encodeURIComponent(PDF_ID));
  });
});
