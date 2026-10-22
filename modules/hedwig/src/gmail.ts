import type { MailFolder, ServerOp } from '@burrow/contracts';
import { parseAddress, parseAddressList } from './addresses';
import { decodeEntities, htmlToText } from './html';
import { buildMime, isInline } from './mime';
import { bearerJson, type Fetch, HttpError, type OAuthSession } from './oauth';
import type {
  BackfillPage,
  MailProviderClient,
  OutgoingMessage,
  ProviderAttachment,
  ProviderMessage,
  SyncResult,
} from './provider';

const API = 'https://gmail.googleapis.com/gmail/v1/users/me';
const INITIAL_MESSAGES = 100;
const BACKFILL_PAGE = 100;

type GmailPart = {
  partId?: string;
  mimeType?: string;
  filename?: string;
  headers?: { name: string; value: string }[];
  body?: { data?: string; attachmentId?: string; size?: number };
  parts?: GmailPart[];
};

export type GmailMessage = {
  id: string;
  threadId: string;
  labelIds?: string[];
  snippet?: string;
  internalDate?: string;
  payload?: GmailPart;
};

type GmailLabel = { id: string; name: string; type: 'system' | 'user' };

type HistoryRecord = {
  messagesAdded?: { message: { id: string } }[];
  messagesDeleted?: { message: { id: string } }[];
  labelsAdded?: { message: { id: string } }[];
  labelsRemoved?: { message: { id: string } }[];
};

export class GmailClient implements MailProviderClient {
  private labels: Map<string, string> | undefined;

  constructor(
    private readonly session: Pick<OAuthSession, 'accessToken'>,
    private readonly fetchFn: Fetch = fetch,
    private readonly pageSize = BACKFILL_PAGE,
  ) {}

  private api<T>(path: string, init?: RequestInit) {
    return bearerJson<T>(this.session, `${API}${path}`, init, this.fetchFn);
  }

  async address(): Promise<string> {
    return (await this.api<{ emailAddress: string }>('/profile')).emailAddress;
  }

  async sync(cursor: string | null): Promise<SyncResult> {
    if (cursor !== null) {
      try {
        return await this.incremental(cursor);
      } catch (error) {
        // A history id older than about a week is gone; start over.
        if (!(error instanceof HttpError && error.status === 404)) throw error;
      }
    }
    const { historyId } = await this.api<{ historyId: string }>('/profile');
    const list = await this.api<{ messages?: { id: string }[] }>(
      `/messages?labelIds=INBOX&maxResults=${INITIAL_MESSAGES}`,
    );
    const ids = (list.messages ?? []).map((m) => m.id);
    const { upserts, removed } = await this.fetchMessages(ids);
    return { upserts, removed, cursor: historyId };
  }

  // Without labelIds the list holds every message except spam and trash.
  async backfill(page: string | null): Promise<BackfillPage> {
    const list = await this.api<{
      messages?: { id: string }[];
      nextPageToken?: string;
    }>(
      `/messages?maxResults=${this.pageSize}${page ? `&pageToken=${page}` : ''}`,
    );
    const { upserts } = await this.fetchMessages(
      (list.messages ?? []).map((m) => m.id),
    );
    return { messages: upserts, next: list.nextPageToken ?? null };
  }

  private async incremental(cursor: string): Promise<SyncResult> {
    const changed = new Set<string>();
    const deleted = new Set<string>();
    let pageToken: string | undefined;
    let historyId = cursor;
    do {
      const page = await this.api<{
        history?: HistoryRecord[];
        historyId: string;
        nextPageToken?: string;
      }>(
        `/history?startHistoryId=${cursor}${pageToken ? `&pageToken=${pageToken}` : ''}`,
      );
      for (const h of page.history ?? []) {
        for (const r of [
          ...(h.messagesAdded ?? []),
          ...(h.labelsAdded ?? []),
          ...(h.labelsRemoved ?? []),
        ]) {
          changed.add(r.message.id);
        }
        for (const r of h.messagesDeleted ?? []) deleted.add(r.message.id);
      }
      historyId = page.historyId;
      pageToken = page.nextPageToken;
    } while (pageToken);

    for (const id of deleted) changed.delete(id);
    const { upserts, removed } = await this.fetchMessages([...changed]);
    return { upserts, removed: [...deleted, ...removed], cursor: historyId };
  }

  private async fetchMessages(ids: string[]) {
    const upserts: ProviderMessage[] = [];
    const removed: string[] = [];
    const labels = await this.labelNames();
    for (const id of ids) {
      try {
        const raw = await this.api<GmailMessage>(`/messages/${id}?format=full`);
        // Drafts live in Hedwig's composer, not in the mail list.
        if (raw.labelIds?.includes('DRAFT')) continue;
        upserts.push(parseGmailMessage(raw, labels));
      } catch (error) {
        if (error instanceof HttpError && error.status === 404)
          removed.push(id);
        else throw error;
      }
    }
    return { upserts, removed };
  }

  private async labelNames(): Promise<Map<string, string>> {
    if (!this.labels) {
      const { labels = [] } = await this.api<{ labels?: GmailLabel[] }>(
        '/labels',
      );
      this.labels = new Map(
        labels.filter((l) => l.type === 'user').map((l) => [l.id, l.name]),
      );
    }
    return this.labels;
  }

  private async labelId(name: string): Promise<string> {
    const labels = await this.labelNames();
    for (const [id, n] of labels) if (n === name) return id;
    const created = await this.api<GmailLabel>('/labels', {
      method: 'POST',
      body: JSON.stringify({
        name,
        labelListVisibility: 'labelShow',
        messageListVisibility: 'show',
      }),
    });
    labels.set(created.id, created.name);
    return created.id;
  }

  async apply(providerId: string, ops: ServerOp[]): Promise<void> {
    const add = new Set<string>();
    const remove = new Set<string>();
    for (const o of ops) {
      switch (o.op) {
        case 'markRead':
          remove.add('UNREAD');
          break;
        case 'markUnread':
          add.add('UNREAD');
          break;
        case 'moveToSpam':
          add.add('SPAM');
          remove.add('INBOX');
          break;
        case 'moveToInbox':
          add.add('INBOX');
          remove.add('SPAM');
          remove.add('TRASH');
          break;
        case 'archive':
          remove.add('INBOX');
          break;
        case 'trash':
          add.add('TRASH');
          remove.add('INBOX');
          break;
        case 'flag':
          add.add('STARRED');
          break;
        case 'unflag':
          remove.add('STARRED');
          break;
        case 'addLabel':
          add.add(await this.labelId(o.label));
          break;
        case 'removeLabel':
          remove.add(await this.labelId(o.label));
          break;
      }
    }
    for (const id of add) remove.delete(id);
    await this.api(`/messages/${providerId}/modify`, {
      method: 'POST',
      body: JSON.stringify({
        addLabelIds: [...add],
        removeLabelIds: [...remove],
      }),
    });
  }

  async send(message: OutgoingMessage): Promise<void> {
    const raw = Buffer.from(buildMime(message), 'utf8').toString('base64url');
    await this.api('/messages/send', {
      method: 'POST',
      body: JSON.stringify({
        raw,
        threadId: message.replyTo?.threadId ?? undefined,
      }),
    });
  }

  async attachments(providerId: string): Promise<ProviderAttachment[]> {
    const raw = await this.api<GmailMessage>(
      `/messages/${providerId}?format=full`,
    );
    return attachmentParts(raw).map((p) => p.attachment);
  }

  // Gmail hands out a new attachmentId with every messages.get, so the listed
  // id is the partId and the current attachmentId is looked up here.
  async attachment(
    providerId: string,
    attachmentId: string,
  ): Promise<Uint8Array> {
    const raw = await this.api<GmailMessage>(
      `/messages/${providerId}?format=full`,
    );
    const found = attachmentParts(raw).find(
      (p) => p.attachment.id === attachmentId,
    );
    if (!found)
      throw new Error(`no attachment ${attachmentId} on this message`);
    const { body } = found.part;
    const data = body?.attachmentId
      ? (
          await this.api<{ data: string }>(
            `/messages/${providerId}/attachments/${encodeURIComponent(body.attachmentId)}`,
          )
        ).data
      : (body?.data ?? '');
    return Buffer.from(data, 'base64url');
  }
}

export function parseGmailMessage(
  raw: GmailMessage,
  userLabels: Map<string, string>,
): ProviderMessage {
  const labelIds = raw.labelIds ?? [];
  const header = (name: string) =>
    raw.payload?.headers?.find(
      (h) => h.name.toLowerCase() === name.toLowerCase(),
    )?.value;
  const body = {
    text: null as string | null,
    html: null as string | null,
    attachments: false,
  };
  walkParts(raw.payload, body);

  return {
    providerId: raw.id,
    threadId: raw.threadId,
    from: parseAddress(header('From') ?? ''),
    to: parseAddressList(header('To')),
    cc: parseAddressList(header('Cc')),
    subject: header('Subject') ?? '',
    snippet: decodeEntities(raw.snippet ?? ''),
    receivedAt: new Date(Number(raw.internalDate ?? Date.now())),
    folder: folderFor(labelIds),
    unread: labelIds.includes('UNREAD'),
    flagged: labelIds.includes('STARRED'),
    labels: labelIds.flatMap((id) => {
      const name = userLabels.get(id);
      return name ? [name] : [];
    }),
    hasAttachments: body.attachments,
    bodyText: body.text ?? (body.html ? htmlToText(body.html) : null),
    bodyHtml: body.html,
    headers: {
      messageId: header('Message-ID') ?? header('Message-Id'),
      references: header('References'),
      authenticationResults: header('Authentication-Results'),
      listUnsubscribe: header('List-Unsubscribe'),
    },
  };
}

function folderFor(labelIds: string[]): MailFolder {
  if (labelIds.includes('TRASH')) return 'trash';
  if (labelIds.includes('SPAM')) return 'spam';
  if (labelIds.includes('INBOX')) return 'inbox';
  if (labelIds.includes('SENT')) return 'sent';
  return 'archive';
}

// The same parts walkParts counts as attachments, so the list matches
// hasAttachments. A forwarded message is one attachment, not its contents.
function attachmentParts(raw: GmailMessage) {
  const found: { part: GmailPart; attachment: ProviderAttachment }[] = [];
  const visit = (part: GmailPart | undefined) => {
    if (!part) return;
    if (part.filename && (part.body?.attachmentId || part.body?.size)) {
      const header = (name: string) =>
        part.headers?.find((h) => h.name.toLowerCase() === name)?.value;
      found.push({
        part,
        attachment: {
          // Only a message that is nothing but the file has an empty partId.
          id: part.partId || '0',
          name: part.filename,
          contentType: part.mimeType || 'application/octet-stream',
          size: part.body?.size ?? 0,
          inline: isInline(header('content-disposition'), header('content-id')),
        },
      });
      return;
    }
    for (const p of part.parts ?? []) visit(p);
  };
  visit(raw.payload);
  return found;
}

function walkParts(
  part: GmailPart | undefined,
  out: { text: string | null; html: string | null; attachments: boolean },
) {
  if (!part) return;
  if (part.filename && (part.body?.attachmentId || part.body?.size)) {
    out.attachments = true;
    return;
  }
  const data = part.body?.data;
  if (data && part.mimeType === 'text/plain' && out.text === null) {
    out.text = Buffer.from(data, 'base64url').toString('utf8');
  } else if (data && part.mimeType === 'text/html' && out.html === null) {
    out.html = Buffer.from(data, 'base64url').toString('utf8');
  }
  for (const p of part.parts ?? []) walkParts(p, out);
}
