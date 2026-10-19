import type { Address, MailFolder, ServerOp } from '@burrow/contracts';
import { htmlToText } from './html';
import { bearerJson, type Fetch, HttpError, type OAuthSession } from './oauth';
import type {
  MailProviderClient,
  OutgoingMessage,
  ProviderMessage,
  SyncResult,
} from './provider';

const API = 'https://graph.microsoft.com/v1.0/me';
const INITIAL_DAYS = 30;
const TRACKED = ['inbox', 'junkemail'] as const;
const FOLDERS: Record<string, MailFolder> = {
  inbox: 'inbox',
  junkemail: 'spam',
  archive: 'archive',
  deleteditems: 'trash',
  sentitems: 'sent',
};
const SELECT = [
  'id',
  'conversationId',
  'subject',
  'bodyPreview',
  'from',
  'toRecipients',
  'ccRecipients',
  'receivedDateTime',
  'isRead',
  'isDraft',
  'flag',
  'categories',
  'hasAttachments',
  'parentFolderId',
  'internetMessageId',
].join(',');

type Recipient = { emailAddress: { name?: string; address: string } };

export type GraphMessage = {
  id: string;
  conversationId?: string;
  subject?: string;
  bodyPreview?: string;
  body?: { contentType: 'html' | 'text'; content: string };
  from?: Recipient;
  toRecipients?: Recipient[];
  ccRecipients?: Recipient[];
  receivedDateTime: string;
  isRead: boolean;
  isDraft?: boolean;
  flag?: { flagStatus: 'flagged' | 'notFlagged' | 'complete' };
  categories?: string[];
  hasAttachments: boolean;
  parentFolderId: string;
  internetMessageId?: string;
  internetMessageHeaders?: { name: string; value: string }[];
};

type DeltaPage = {
  value: (GraphMessage | { id: string; '@removed': object })[];
  '@odata.nextLink'?: string;
  '@odata.deltaLink'?: string;
};

// Immutable ids keep a message's id stable when it moves between folders, so
// archiving or junking does not look like a delete plus a new message.
const IMMUTABLE = { Prefer: 'IdType="ImmutableId"' };

export class GraphClient implements MailProviderClient {
  private folderIds: Map<string, MailFolder> | undefined;

  constructor(
    private readonly session: Pick<OAuthSession, 'accessToken'>,
    private readonly fetchFn: Fetch = fetch,
    private readonly now: () => Date = () => new Date(),
  ) {}

  private api<T>(pathOrUrl: string, init: RequestInit = {}) {
    const url = pathOrUrl.startsWith('https://')
      ? pathOrUrl
      : `${API}${pathOrUrl}`;
    return bearerJson<T>(
      this.session,
      url,
      { ...init, headers: { ...IMMUTABLE, ...init.headers } },
      this.fetchFn,
    );
  }

  async address(): Promise<string> {
    const me = await this.api<{ mail?: string; userPrincipalName: string }>('');
    return me.mail ?? me.userPrincipalName;
  }

  // The cursor holds one delta link per tracked folder. Mail that leaves a
  // tracked folder shows up as removed there; fetching it by its immutable id
  // tells whether it moved (archive, trash) or is really gone.
  async sync(cursor: string | null): Promise<SyncResult> {
    const links: Record<string, string> = cursor ? JSON.parse(cursor) : {};
    const changed = new Set<string>();
    const left = new Set<string>();
    for (const folder of TRACKED) {
      let url =
        links[folder] ??
        `/mailFolders/${folder}/messages/delta?$select=${SELECT}&$filter=receivedDateTime+ge+${this.since()}`;
      for (;;) {
        const page = await this.api<DeltaPage>(url, {
          headers: { Prefer: `IdType="ImmutableId", odata.maxpagesize=50` },
        });
        for (const item of page.value) {
          if ('@removed' in item) left.add(item.id);
          else changed.add(item.id);
        }
        if (page['@odata.nextLink']) {
          url = page['@odata.nextLink'];
          continue;
        }
        links[folder] = page['@odata.deltaLink']!;
        break;
      }
    }
    for (const id of changed) left.delete(id);

    const upserts: ProviderMessage[] = [];
    const removed: string[] = [];
    for (const id of [...changed, ...left]) {
      try {
        const message = await this.message(id);
        if (!message.isDraft) upserts.push(await this.parse(message));
      } catch (error) {
        if (error instanceof HttpError && error.status === 404)
          removed.push(id);
        else throw error;
      }
    }
    return { upserts, removed, cursor: JSON.stringify(links) };
  }

  private since() {
    const date = new Date(this.now().getTime() - INITIAL_DAYS * 86_400_000);
    return date.toISOString().replace(/\.\d+Z$/, 'Z');
  }

  private message(id: string) {
    return this.api<GraphMessage>(
      `/messages/${id}?$select=${SELECT},body,internetMessageHeaders`,
    );
  }

  private async folders(): Promise<Map<string, MailFolder>> {
    if (!this.folderIds) {
      const map = new Map<string, MailFolder>();
      for (const [wellKnown, folder] of Object.entries(FOLDERS)) {
        try {
          const { id } = await this.api<{ id: string }>(
            `/mailFolders/${wellKnown}`,
          );
          map.set(id, folder);
        } catch (error) {
          // Personal accounts without an Archive folder answer 404.
          if (!(error instanceof HttpError && error.status === 404))
            throw error;
        }
      }
      this.folderIds = map;
    }
    return this.folderIds;
  }

  async parse(m: GraphMessage): Promise<ProviderMessage> {
    const folders = await this.folders();
    const header = (name: string) =>
      m.internetMessageHeaders?.find(
        (h) => h.name.toLowerCase() === name.toLowerCase(),
      )?.value;
    const html = m.body?.contentType === 'html' ? m.body.content : null;
    return {
      providerId: m.id,
      threadId: m.conversationId ?? null,
      from: toAddress(m.from) ?? { email: '' },
      to: (m.toRecipients ?? []).flatMap((r) => toAddress(r) ?? []),
      cc: (m.ccRecipients ?? []).flatMap((r) => toAddress(r) ?? []),
      subject: m.subject ?? '',
      snippet: m.bodyPreview ?? '',
      receivedAt: new Date(m.receivedDateTime),
      folder: folders.get(m.parentFolderId) ?? 'archive',
      unread: !m.isRead,
      flagged: m.flag?.flagStatus === 'flagged',
      labels: m.categories ?? [],
      hasAttachments: m.hasAttachments,
      bodyText: html !== null ? htmlToText(html) : (m.body?.content ?? null),
      bodyHtml: html,
      headers: {
        messageId: m.internetMessageId ?? header('Message-ID'),
        references: header('References'),
        authenticationResults: header('Authentication-Results'),
        listUnsubscribe: header('List-Unsubscribe'),
      },
    };
  }

  async apply(providerId: string, ops: ServerOp[]): Promise<void> {
    const patch: Record<string, unknown> = {};
    let destination: string | undefined;
    let categories: Set<string> | undefined;
    for (const o of ops) {
      switch (o.op) {
        case 'markRead':
          patch.isRead = true;
          break;
        case 'markUnread':
          patch.isRead = false;
          break;
        case 'flag':
          patch.flag = { flagStatus: 'flagged' };
          break;
        case 'unflag':
          patch.flag = { flagStatus: 'notFlagged' };
          break;
        case 'moveToSpam':
          destination = 'junkemail';
          break;
        case 'moveToInbox':
          destination = 'inbox';
          break;
        case 'archive':
          destination = 'archive';
          break;
        case 'trash':
          destination = 'deleteditems';
          break;
        case 'addLabel':
        case 'removeLabel': {
          categories ??= new Set(
            (
              await this.api<{ categories?: string[] }>(
                `/messages/${providerId}?$select=categories`,
              )
            ).categories ?? [],
          );
          if (o.op === 'addLabel') categories.add(o.label);
          else categories.delete(o.label);
          break;
        }
      }
    }
    if (categories) patch.categories = [...categories];
    if (Object.keys(patch).length) {
      await this.api(`/messages/${providerId}`, {
        method: 'PATCH',
        body: JSON.stringify(patch),
      });
    }
    if (destination) {
      await this.api(`/messages/${providerId}/move`, {
        method: 'POST',
        body: JSON.stringify({ destinationId: destination }),
      });
    }
  }

  async send(message: OutgoingMessage): Promise<void> {
    const recipients = (list: Address[]) =>
      list.map((a) => ({ emailAddress: { name: a.name, address: a.email } }));
    if (message.replyTo) {
      // Replying through Graph keeps the conversation and threading headers.
      await this.api(`/messages/${message.replyTo.providerId}/reply`, {
        method: 'POST',
        body: JSON.stringify({
          message: {
            toRecipients: recipients(message.to),
            ccRecipients: recipients(message.cc),
          },
          comment: message.body,
        }),
      });
      return;
    }
    await this.api('/sendMail', {
      method: 'POST',
      body: JSON.stringify({
        message: {
          subject: message.subject,
          body: { contentType: 'Text', content: message.body },
          toRecipients: recipients(message.to),
          ccRecipients: recipients(message.cc),
        },
        saveToSentItems: true,
      }),
    });
  }
}

function toAddress(r: Recipient | undefined): Address | undefined {
  if (!r?.emailAddress?.address) return undefined;
  const { name, address } = r.emailAddress;
  return name && name !== address
    ? { name, email: address }
    : { email: address };
}
