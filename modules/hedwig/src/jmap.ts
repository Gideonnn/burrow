import type { Address, MailFolder, ServerOp } from '@burrow/contracts';
import { htmlToText } from './html';
import type { Fetch } from './oauth';
import type {
  MailProviderClient,
  OutgoingMessage,
  ProviderMessage,
  SyncResult,
} from './provider';

export const FASTMAIL_SESSION_URL = 'https://api.fastmail.com/jmap/session';
const USING = [
  'urn:ietf:params:jmap:core',
  'urn:ietf:params:jmap:mail',
  'urn:ietf:params:jmap:submission',
];
const INITIAL_MESSAGES = 100;

const PROPERTIES = [
  'id',
  'threadId',
  'mailboxIds',
  'keywords',
  'from',
  'to',
  'cc',
  'subject',
  'preview',
  'receivedAt',
  'hasAttachment',
  'messageId',
  'references',
  'textBody',
  'htmlBody',
  'bodyValues',
  'header:Authentication-Results:asText',
  'header:List-Unsubscribe:asText',
];

type JmapAddress = { name?: string | null; email: string };
type BodyPart = { partId: string; type: string };

export type JmapEmail = {
  id: string;
  threadId: string;
  mailboxIds: Record<string, true>;
  keywords: Record<string, true>;
  from?: JmapAddress[] | null;
  to?: JmapAddress[] | null;
  cc?: JmapAddress[] | null;
  subject?: string | null;
  preview?: string;
  receivedAt: string;
  hasAttachment: boolean;
  messageId?: string[] | null;
  references?: string[] | null;
  textBody?: BodyPart[];
  htmlBody?: BodyPart[];
  bodyValues?: Record<string, { value: string }>;
  'header:Authentication-Results:asText'?: string | null;
  'header:List-Unsubscribe:asText'?: string | null;
};

type Session = { apiUrl: string; accountId: string; username: string };
type Invocation = [string, Record<string, unknown>, string];

export class JmapError extends Error {
  constructor(
    readonly type: string,
    message: string,
  ) {
    super(message);
  }
}

export class JmapClient implements MailProviderClient {
  private session: Session | undefined;
  private roles: Map<string, string> | undefined;

  constructor(
    private readonly token: string,
    private readonly fetchFn: Fetch = fetch,
    private readonly sessionUrl = FASTMAIL_SESSION_URL,
  ) {}

  private async getSession(): Promise<Session> {
    if (!this.session) {
      const res = await this.fetchFn(this.sessionUrl, {
        headers: { authorization: `Bearer ${this.token}` },
      });
      if (!res.ok) throw new Error(`JMAP session failed: ${res.status}`);
      const body = (await res.json()) as {
        apiUrl: string;
        username: string;
        primaryAccounts: Record<string, string>;
      };
      const accountId = body.primaryAccounts['urn:ietf:params:jmap:mail'];
      if (!accountId) throw new Error('this token has no mail access');
      this.session = {
        apiUrl: body.apiUrl,
        accountId,
        username: body.username,
      };
    }
    return this.session;
  }

  // Runs method calls in one request and returns the responses by tag,
  // throwing on the first method error.
  private async call(
    calls: Invocation[],
  ): Promise<Map<string, Record<string, any>>> {
    const { apiUrl, accountId } = await this.getSession();
    const res = await this.fetchFn(apiUrl, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${this.token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        using: USING,
        methodCalls: calls.map(([name, args, tag]) => [
          name,
          { accountId, ...args },
          tag,
        ]),
      }),
    });
    if (!res.ok)
      throw new Error(`JMAP request failed: ${res.status} ${await res.text()}`);
    const { methodResponses } = (await res.json()) as {
      methodResponses: [string, Record<string, any>, string][];
    };
    const byTag = new Map<string, Record<string, any>>();
    for (const [name, result, tag] of methodResponses) {
      if (name === 'error')
        throw new JmapError(
          result.type,
          `${tag}: ${result.type} ${result.description ?? ''}`,
        );
      byTag.set(tag, result);
    }
    return byTag;
  }

  async address(): Promise<string> {
    return (await this.getSession()).username;
  }

  private async mailboxRoles(): Promise<Map<string, string>> {
    if (!this.roles) {
      const r = await this.call([
        ['Mailbox/get', { properties: ['id', 'role'] }, 'm'],
      ]);
      const list = r.get('m')!.list as { id: string; role: string | null }[];
      this.roles = new Map(
        list.flatMap((m) =>
          m.role ? [[m.role, m.id] as [string, string]] : [],
        ),
      );
    }
    return this.roles;
  }

  private async role(name: string): Promise<string> {
    const id = (await this.mailboxRoles()).get(name);
    if (!id) throw new Error(`this account has no ${name} mailbox`);
    return id;
  }

  async sync(cursor: string | null): Promise<SyncResult> {
    if (cursor !== null) {
      try {
        return await this.incremental(cursor);
      } catch (error) {
        if (
          !(
            error instanceof JmapError &&
            error.type === 'cannotCalculateChanges'
          )
        )
          throw error;
      }
    }
    const inbox = await this.role('inbox');
    const r = await this.call([
      [
        'Email/query',
        {
          filter: { inMailbox: inbox },
          sort: [{ property: 'receivedAt', isAscending: false }],
          limit: INITIAL_MESSAGES,
        },
        'q',
      ],
      [
        'Email/get',
        {
          '#ids': { resultOf: 'q', name: 'Email/query', path: '/ids' },
          ...this.getArgs(),
        },
        'g',
      ],
    ]);
    const get = r.get('g')!;
    return {
      upserts: await this.parseAll(get.list),
      removed: [],
      cursor: get.state,
    };
  }

  private async incremental(cursor: string): Promise<SyncResult> {
    const changed = new Set<string>();
    const destroyed = new Set<string>();
    let state = cursor;
    for (;;) {
      const r = await this.call([
        ['Email/changes', { sinceState: state }, 'c'],
      ]);
      const c = r.get('c')!;
      for (const id of [...c.created, ...c.updated]) changed.add(id);
      for (const id of c.destroyed) destroyed.add(id);
      state = c.newState;
      if (!c.hasMoreChanges) break;
    }
    for (const id of destroyed) changed.delete(id);
    if (!changed.size)
      return { upserts: [], removed: [...destroyed], cursor: state };
    const r = await this.call([
      ['Email/get', { ids: [...changed], ...this.getArgs() }, 'g'],
    ]);
    const get = r.get('g')!;
    return {
      upserts: await this.parseAll(get.list),
      removed: [...destroyed, ...(get.notFound ?? [])],
      cursor: state,
    };
  }

  private getArgs() {
    return {
      properties: PROPERTIES,
      fetchTextBodyValues: true,
      fetchHTMLBodyValues: true,
      maxBodyValueBytes: 256_000,
    };
  }

  private async parseAll(list: JmapEmail[]): Promise<ProviderMessage[]> {
    const roles = await this.mailboxRoles();
    const roleOf = new Map([...roles].map(([role, id]) => [id, role]));
    return list
      .filter((e) => !e.keywords.$draft)
      .map((e) => parseJmapEmail(e, roleOf));
  }

  async apply(providerId: string, ops: ServerOp[]): Promise<void> {
    const patch: Record<string, unknown> = {};
    for (const o of ops) {
      switch (o.op) {
        case 'markRead':
          patch['keywords/$seen'] = true;
          break;
        case 'markUnread':
          patch['keywords/$seen'] = null;
          break;
        case 'flag':
          patch['keywords/$flagged'] = true;
          break;
        case 'unflag':
          patch['keywords/$flagged'] = null;
          break;
        case 'addLabel':
          patch[`keywords/${keyword(o.label)}`] = true;
          break;
        case 'removeLabel':
          patch[`keywords/${keyword(o.label)}`] = null;
          break;
        case 'moveToSpam':
          patch.mailboxIds = { [await this.role('junk')]: true };
          break;
        case 'moveToInbox':
          patch.mailboxIds = { [await this.role('inbox')]: true };
          break;
        case 'archive':
          patch.mailboxIds = { [await this.role('archive')]: true };
          break;
        case 'trash':
          patch.mailboxIds = { [await this.role('trash')]: true };
          break;
      }
    }
    const r = await this.call([
      ['Email/set', { update: { [providerId]: patch } }, 's'],
    ]);
    const failed = r.get('s')!.notUpdated?.[providerId];
    if (failed) throw new Error(`update refused: ${failed.type}`);
  }

  async send(message: OutgoingMessage): Promise<void> {
    const [drafts, sent] = [await this.role('drafts'), await this.role('sent')];
    const identities = (await this.call([['Identity/get', {}, 'i']])).get('i')!
      .list as {
      id: string;
      email: string;
    }[];
    const identity =
      identities.find(
        (i) => i.email.toLowerCase() === message.from.email.toLowerCase(),
      ) ?? identities[0];
    if (!identity) throw new Error('no sending identity for this account');

    const parent = message.replyTo?.headers.messageId;
    const strip = (id: string) => id.replace(/^<|>$/g, '');
    const references = [
      ...(message.replyTo?.headers.references?.split(/\s+/).filter(Boolean) ??
        []),
      ...(parent ? [parent] : []),
    ].map(strip);
    const toJmap = (list: Address[]) =>
      list.map((a) => ({ name: a.name ?? null, email: a.email }));

    const r = await this.call([
      [
        'Email/set',
        {
          create: {
            draft: {
              mailboxIds: { [drafts]: true },
              keywords: { $draft: true, $seen: true },
              from: toJmap([message.from]),
              to: toJmap(message.to),
              cc: toJmap(message.cc),
              subject: message.subject,
              ...(parent ? { inReplyTo: [strip(parent)], references } : {}),
              bodyValues: { body: { value: message.body } },
              textBody: [{ partId: 'body', type: 'text/plain' }],
            },
          },
        },
        'e',
      ],
      [
        'EmailSubmission/set',
        {
          create: { s: { identityId: identity.id, emailId: '#draft' } },
          onSuccessUpdateEmail: {
            '#s': {
              [`mailboxIds/${drafts}`]: null,
              [`mailboxIds/${sent}`]: true,
              'keywords/$draft': null,
            },
          },
        },
        'x',
      ],
    ]);
    const notCreated =
      r.get('x')?.notCreated?.s ?? r.get('e')?.notCreated?.draft;
    if (notCreated) throw new Error(`sending refused: ${notCreated.type}`);
  }
}

export function parseJmapEmail(
  e: JmapEmail,
  roleOf: Map<string, string>,
): ProviderMessage {
  const roles = Object.keys(e.mailboxIds).map((id) => roleOf.get(id));
  const text = joinParts(e.textBody, e.bodyValues);
  const html = joinParts(
    e.htmlBody?.filter((p) => p.type === 'text/html'),
    e.bodyValues,
  );
  return {
    providerId: e.id,
    threadId: e.threadId,
    from: toAddress(e.from?.[0]) ?? { email: '' },
    to: (e.to ?? []).map((a) => toAddress(a)!),
    cc: (e.cc ?? []).map((a) => toAddress(a)!),
    subject: e.subject ?? '',
    snippet: e.preview ?? '',
    receivedAt: new Date(e.receivedAt),
    folder: folderFor(roles),
    unread: !e.keywords.$seen,
    flagged: Boolean(e.keywords.$flagged),
    labels: Object.keys(e.keywords).filter((k) => !k.startsWith('$')),
    hasAttachments: e.hasAttachment,
    bodyText: text ?? (html ? htmlToText(html) : null),
    bodyHtml: html,
    headers: {
      messageId: e.messageId?.[0] ? `<${e.messageId[0]}>` : undefined,
      references: e.references?.map((r) => `<${r}>`).join(' ') || undefined,
      authenticationResults:
        e['header:Authentication-Results:asText'] ?? undefined,
      listUnsubscribe: e['header:List-Unsubscribe:asText'] ?? undefined,
    },
  };
}

function folderFor(roles: (string | undefined)[]): MailFolder {
  if (roles.includes('trash')) return 'trash';
  if (roles.includes('junk')) return 'spam';
  if (roles.includes('inbox')) return 'inbox';
  if (roles.includes('sent')) return 'sent';
  return 'archive';
}

function joinParts(
  parts: BodyPart[] | undefined,
  values: JmapEmail['bodyValues'],
): string | null {
  const texts = (parts ?? []).flatMap((p) => {
    const v = values?.[p.partId]?.value;
    return v === undefined ? [] : [v];
  });
  return texts.length ? texts.join('\n') : null;
}

function toAddress(a: JmapAddress | undefined): Address | undefined {
  if (!a) return undefined;
  return a.name ? { name: a.name, email: a.email } : { email: a.email };
}

// JMAP keywords are ASCII without spaces or brackets; labels like "Bon" or
// "Factuur" pass through, anything else is made safe.
function keyword(label: string): string {
  return label.replace(/[^\x21-\x7e]|[()[\]{}%*"\\]/g, '_');
}
