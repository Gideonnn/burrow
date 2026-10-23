import { describe, expect, it } from 'vitest';
import { GmailClient, type GmailMessage } from './gmail';

const b64 = (s: string) => Buffer.from(s, 'utf8').toString('base64url');

function message(
  id: string,
  labelIds: string[],
  subject = `Subject ${id}`,
): GmailMessage {
  return {
    id,
    threadId: `t-${id}`,
    labelIds,
    snippet: 'Tom &amp; Jerry&#39;s',
    internalDate: String(Date.parse('2026-10-19T08:00:00Z')),
    payload: {
      mimeType: 'multipart/mixed',
      headers: [
        { name: 'From', value: '"Doe, Jane" <jane@example.com>' },
        { name: 'To', value: 'owner@example.com, Bob <bob@example.com>' },
        { name: 'Reply-To', value: 'Support <help@example.com>' },
        { name: 'Subject', value: subject },
        { name: 'Message-ID', value: `<${id}@example.com>` },
        { name: 'List-Unsubscribe', value: '<mailto:unsub@example.com>' },
      ],
      parts: [
        {
          mimeType: 'multipart/alternative',
          parts: [
            { mimeType: 'text/plain', body: { data: b64('Hallo daar') } },
            { mimeType: 'text/html', body: { data: b64('<p>Hallo daar</p>') } },
          ],
        },
        {
          mimeType: 'application/pdf',
          filename: 'factuur.pdf',
          body: { attachmentId: 'a1', size: 100 },
        },
      ],
    },
  };
}

// A tiny in-memory Gmail API: enough of profile, messages, history, labels,
// modify and send to exercise the client end to end.
function fakeGmail() {
  const messages = new Map<string, GmailMessage>();
  const history: { id: number; record: object }[] = [];
  let historyId = 100;
  let oldestHistory = 100;
  const labels = [
    { id: 'INBOX', name: 'INBOX', type: 'system' },
    { id: 'Label_1', name: 'Bon', type: 'user' },
  ];
  const sent: { raw: string; threadId?: string }[] = [];
  const modifies: { id: string; add: string[]; remove: string[] }[] = [];
  let unauthorizedOnce = false;
  let tokenCalls = 0;

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json' },
    });

  const fetchFn = async (
    input: string | URL | Request,
    init: RequestInit = {},
  ) => {
    const url = new URL(String(input));
    const path = url.pathname.replace('/gmail/v1/users/me', '');
    const method = init.method ?? 'GET';
    if (unauthorizedOnce) {
      unauthorizedOnce = false;
      return new Response('expired', { status: 401 });
    }
    if (path === '/profile')
      return json({
        emailAddress: 'owner@example.com',
        historyId: String(historyId),
      });
    if (path === '/messages' && method === 'GET') {
      const label = url.searchParams.get('labelIds');
      // Newest first; without a label Gmail leaves out spam and trash.
      const matching = [...messages.values()]
        .reverse()
        .filter((m) =>
          label
            ? m.labelIds?.includes(label)
            : !m.labelIds?.some((l) => l === 'SPAM' || l === 'TRASH'),
        );
      const start = Number(url.searchParams.get('pageToken') ?? 0);
      const end = start + Number(url.searchParams.get('maxResults') ?? 100);
      return json({
        messages: matching.slice(start, end).map((m) => ({ id: m.id })),
        ...(end < matching.length ? { nextPageToken: String(end) } : {}),
      });
    }
    const one = /^\/messages\/([^/]+)$/.exec(path);
    if (one && method === 'GET') {
      const m = messages.get(one[1]!);
      return m ? json(m) : json({ error: 'gone' }, 404);
    }
    if (path === '/history') {
      const start = Number(url.searchParams.get('startHistoryId'));
      if (start < oldestHistory) return json({ error: 'too old' }, 404);
      return json({
        history: history.filter((h) => h.id > start).map((h) => h.record),
        historyId: String(historyId),
      });
    }
    if (path === '/labels' && method === 'GET') return json({ labels });
    if (path === '/labels' && method === 'POST') {
      const body = JSON.parse(String(init.body));
      const label = {
        id: `Label_${labels.length}`,
        name: body.name,
        type: 'user',
      };
      labels.push(label);
      return json(label);
    }
    const modify = /^\/messages\/([^/]+)\/modify$/.exec(path);
    if (modify) {
      const body = JSON.parse(String(init.body));
      modifies.push({
        id: modify[1]!,
        add: body.addLabelIds,
        remove: body.removeLabelIds,
      });
      return json({});
    }
    if (path === '/messages/send') {
      sent.push(JSON.parse(String(init.body)));
      return json({ id: 'sent-1' });
    }
    return json({ error: `unhandled ${method} ${path}` }, 500);
  };

  return {
    fetchFn: fetchFn as typeof fetch,
    sent,
    modifies,
    session: {
      accessToken: async ({ force = false } = {}) => (
        force && tokenCalls++,
        'token'
      ),
    },
    get tokenRefreshes() {
      return tokenCalls;
    },
    deliver(m: GmailMessage) {
      messages.set(m.id, m);
      history.push({
        id: ++historyId,
        record: { messagesAdded: [{ message: { id: m.id } }] },
      });
    },
    relabel(id: string, labelIds: string[]) {
      messages.get(id)!.labelIds = labelIds;
      history.push({
        id: ++historyId,
        record: { labelsAdded: [{ message: { id } }] },
      });
    },
    delete(id: string) {
      messages.delete(id);
      history.push({
        id: ++historyId,
        record: { messagesDeleted: [{ message: { id } }] },
      });
    },
    expireHistory() {
      oldestHistory = historyId + 1;
    },
    expireToken() {
      unauthorizedOnce = true;
    },
  };
}

describe('GmailClient', () => {
  it('parses a full message: addresses, bodies, attachments, labels and triage headers', async () => {
    const api = fakeGmail();
    api.deliver(message('a', ['INBOX', 'UNREAD', 'Label_1']));
    const { upserts } = await new GmailClient(api.session, api.fetchFn).sync(
      null,
    );
    expect(upserts[0]).toMatchObject({
      providerId: 'a',
      threadId: 't-a',
      from: { name: 'Doe, Jane', email: 'jane@example.com' },
      to: [
        { email: 'owner@example.com' },
        { name: 'Bob', email: 'bob@example.com' },
      ],
      replyTo: [{ name: 'Support', email: 'help@example.com' }],
      snippet: "Tom & Jerry's",
      folder: 'inbox',
      unread: true,
      labels: ['Bon'],
      hasAttachments: true,
      bodyText: 'Hallo daar',
      bodyHtml: '<p>Hallo daar</p>',
      headers: {
        messageId: '<a@example.com>',
        listUnsubscribe: '<mailto:unsub@example.com>',
      },
    });
  });

  it('syncs incrementally from the history cursor', async () => {
    const api = fakeGmail();
    const client = new GmailClient(api.session, api.fetchFn);
    api.deliver(message('a', ['INBOX']));
    const first = await client.sync(null);

    api.deliver(message('b', ['INBOX']));
    api.relabel('a', ['SPAM']);
    const second = await client.sync(first.cursor);
    expect(second.upserts.map((m) => [m.providerId, m.folder]).sort()).toEqual([
      ['a', 'spam'],
      ['b', 'inbox'],
    ]);

    api.delete('b');
    const third = await client.sync(second.cursor);
    expect(third.removed).toEqual(['b']);
  });

  it('starts over when the history cursor has expired', async () => {
    const api = fakeGmail();
    const client = new GmailClient(api.session, api.fetchFn);
    api.deliver(message('a', ['INBOX']));
    const first = await client.sync(null);
    api.expireHistory();
    const again = await client.sync(first.cursor);
    expect(again.upserts.map((m) => m.providerId)).toEqual(['a']);
  });

  it('skips drafts', async () => {
    const api = fakeGmail();
    api.deliver(message('d', ['INBOX', 'DRAFT']));
    expect(
      (await new GmailClient(api.session, api.fetchFn).sync(null)).upserts,
    ).toEqual([]);
  });

  it('backfills every folder but spam and trash, newest first, page by page', async () => {
    const api = fakeGmail();
    const client = new GmailClient(api.session, api.fetchFn, 2);
    api.deliver(message('old', []));
    api.deliver(message('sent', ['SENT']));
    api.deliver(message('junk', ['SPAM']));
    api.deliver(message('draft', ['DRAFT']));
    api.deliver(message('new', ['INBOX']));

    const first = await client.backfill(null);
    expect(first.messages.map((m) => m.providerId)).toEqual(['new']);
    const second = await client.backfill(first.next);
    expect(second.messages.map((m) => [m.providerId, m.folder])).toEqual([
      ['sent', 'sent'],
      ['old', 'archive'],
    ]);
    expect(second.next).toBeNull();
  });

  it('turns server operations into one label change, creating missing labels', async () => {
    const api = fakeGmail();
    const client = new GmailClient(api.session, api.fetchFn);
    await client.apply('a', [
      { op: 'moveToSpam' },
      { op: 'markRead' },
      { op: 'addLabel', label: 'Factuur' },
    ]);
    expect(api.modifies[0]?.add.sort()).toEqual(['Label_2', 'SPAM']);
    expect(api.modifies[0]?.remove.sort()).toEqual(['INBOX', 'UNREAD']);
  });

  it('sends a reply in the same thread with threading headers', async () => {
    const api = fakeGmail();
    await new GmailClient(api.session, api.fetchFn).send({
      from: { name: 'Gideon', email: 'owner@example.com' },
      to: [{ email: 'jane@example.com' }],
      cc: [],
      subject: 'Re: Vraag',
      body: 'Prima!',
      replyTo: {
        providerId: 'a',
        threadId: 't-a',
        headers: { messageId: '<a@example.com>' },
      },
    });
    const mime = Buffer.from(api.sent[0]!.raw, 'base64url').toString('utf8');
    expect(api.sent[0]?.threadId).toBe('t-a');
    expect(mime).toContain('In-Reply-To: <a@example.com>');
    expect(mime).toContain('To: jane@example.com');
  });

  it('retries once with a fresh token after a 401', async () => {
    const api = fakeGmail();
    api.expireToken();
    expect(await new GmailClient(api.session, api.fetchFn).address()).toBe(
      'owner@example.com',
    );
    expect(api.tokenRefreshes).toBe(1);
  });
});

// A message as messages.get returns it with format=full: every part has a
// partId, and the attachmentId is different on every call.
function withAttachments(issue: (partId: string) => string): GmailMessage {
  return {
    id: 'att',
    threadId: 't-att',
    labelIds: ['INBOX'],
    payload: {
      partId: '',
      mimeType: 'multipart/mixed',
      filename: '',
      headers: [{ name: 'Subject', value: 'Offerte en logo' }],
      body: { size: 0 },
      parts: [
        {
          partId: '0',
          mimeType: 'multipart/related',
          filename: '',
          body: { size: 0 },
          parts: [
            {
              partId: '0.0',
              mimeType: 'text/html',
              filename: '',
              body: { size: 31, data: b64('<img src="cid:logo@example.com">') },
            },
            {
              partId: '0.1',
              mimeType: 'image/png',
              filename: 'logo.png',
              headers: [
                { name: 'Content-Type', value: 'image/png; name="logo.png"' },
                {
                  name: 'Content-Disposition',
                  value: 'inline; filename="logo.png"',
                },
                { name: 'Content-ID', value: '<logo@example.com>' },
              ],
              body: { attachmentId: issue('0.1'), size: 4 },
            },
          ],
        },
        {
          partId: '1',
          mimeType: 'application/pdf',
          filename: 'offerte 2026 (def).pdf',
          headers: [
            { name: 'Content-Type', value: 'application/pdf' },
            {
              name: 'Content-Disposition',
              value: 'attachment; filename="offerte 2026 (def).pdf"',
            },
          ],
          body: { attachmentId: issue('1'), size: 9 },
        },
      ],
    },
  };
}

function gmailAttachments() {
  const issued = new Map<string, string>();
  const contents: Record<string, string> = { '0.1': 'PNG!', '1': '%PDF-1.4!' };
  const requests: string[] = [];
  const fetchFn = async (input: string | URL | Request) => {
    const url = new URL(String(input));
    const path = url.pathname.replace('/gmail/v1/users/me', '');
    requests.push(path);
    if (path === '/messages/att') {
      return Response.json(
        withAttachments((partId) => {
          const id = `ANGjdJ-${issued.size + 1}`;
          issued.set(id, partId);
          return id;
        }),
      );
    }
    const part = issued.get(path.replace('/messages/att/attachments/', ''));
    if (part) {
      return Response.json({
        size: contents[part]!.length,
        data: b64(contents[part]!),
      });
    }
    return Response.json({ error: 'not found' }, { status: 404 });
  };
  return {
    client: new GmailClient(
      { accessToken: async () => 'token' },
      fetchFn as typeof fetch,
    ),
    requests,
  };
}

describe('GmailClient attachments', () => {
  it('lists files and inline images by part, with ids that stay the same between calls', async () => {
    const { client } = gmailAttachments();
    const first = await client.attachments('att');
    expect(first).toEqual([
      {
        id: '0.1',
        name: 'logo.png',
        contentType: 'image/png',
        size: 4,
        inline: true,
      },
      {
        id: '1',
        name: 'offerte 2026 (def).pdf',
        contentType: 'application/pdf',
        size: 9,
        inline: false,
      },
    ]);
    expect(await client.attachments('att')).toEqual(first);
  });

  it('downloads a part through the attachment id Gmail hands out right now', async () => {
    const { client, requests } = gmailAttachments();
    await client.attachments('att');
    const data = await client.attachment('att', '1');
    expect(Buffer.from(data).toString()).toBe('%PDF-1.4!');
    expect(requests.at(-1)).toBe('/messages/att/attachments/ANGjdJ-4');
  });
});
