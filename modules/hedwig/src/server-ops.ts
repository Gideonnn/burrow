import type {
  MailFolder,
  MailProvider,
  ServerOp,
  TriageAction,
} from '@burrow/contracts';

// What a triage decision becomes at the provider, so phones using the native
// mail apps see the same result as Hedwig. Spam stays unread: it is only read
// once the person says it is not spam.
export function serverOpsFor(action: TriageAction): ServerOp[] {
  switch (action.kind) {
    case 'keep':
      return [];
    case 'spam':
      return [{ op: 'moveToSpam' }];
    case 'archive':
      return [{ op: 'archive' }, { op: 'markRead' }];
    case 'needs-reply':
      return [{ op: 'flag' }];
    case 'label':
      return [{ op: 'addLabel', label: action.label }];
  }
}

// "Geen spam" lands read, also for entries from when triage marked spam read;
// other filtered mail goes back to the inbox unread.
export function restoreOps(action: TriageAction, ops: ServerOp[]): ServerOp[] {
  const back = reverseOps(ops);
  if (action.kind !== 'spam') return back;
  return [...back.filter((o) => o.op !== 'markUnread'), { op: 'markRead' }];
}

// Undo of a triage decision: back to the inbox and unread, whatever it did.
export function reverseOps(ops: ServerOp[]): ServerOp[] {
  return ops.flatMap((o): ServerOp[] => {
    switch (o.op) {
      case 'moveToSpam':
      case 'archive':
      case 'trash':
        return [{ op: 'moveToInbox' }];
      case 'markRead':
        return [{ op: 'markUnread' }];
      case 'flag':
        return [{ op: 'unflag' }];
      case 'addLabel':
        return [{ op: 'removeLabel', label: o.label }];
      default:
        return [];
    }
  });
}

export type MessageState = {
  folder: MailFolder;
  unread: boolean;
  flagged: boolean;
  labels: string[];
};

// The local mirror of what the provider now holds, applied after the provider
// accepted the operations.
export function applyOps(state: MessageState, ops: ServerOp[]): MessageState {
  const next = { ...state, labels: [...state.labels] };
  for (const o of ops) {
    switch (o.op) {
      case 'markRead':
        next.unread = false;
        break;
      case 'markUnread':
        next.unread = true;
        break;
      case 'moveToSpam':
        next.folder = 'spam';
        break;
      case 'moveToInbox':
        next.folder = 'inbox';
        break;
      case 'archive':
        next.folder = 'archive';
        break;
      case 'trash':
        next.folder = 'trash';
        break;
      case 'flag':
        next.flagged = true;
        break;
      case 'unflag':
        next.flagged = false;
        break;
      case 'addLabel':
        if (!next.labels.includes(o.label)) next.labels.push(o.label);
        break;
      case 'removeLabel':
        next.labels = next.labels.filter((l) => l !== o.label);
        break;
    }
  }
  return next;
}

// Provider vocabulary for each op, shown in the "what happened on the server"
// line in the client.
export function describeOp(provider: MailProvider, op: ServerOp): string {
  const words: Record<ServerOp['op'], Record<MailProvider, string>> = {
    markRead: {
      gmail: 'mark as read',
      microsoft: 'mark as read',
      fastmail: 'keyword $seen',
    },
    markUnread: {
      gmail: 'mark as unread',
      microsoft: 'mark as unread',
      fastmail: 'remove $seen',
    },
    moveToSpam: {
      gmail: 'label SPAM',
      microsoft: 'move to Junk Email',
      fastmail: 'move to Junk',
    },
    moveToInbox: {
      gmail: 'label INBOX',
      microsoft: 'move to Inbox',
      fastmail: 'move to Inbox',
    },
    archive: {
      gmail: 'remove label INBOX',
      microsoft: 'move to Archive',
      fastmail: 'move to Archive',
    },
    trash: {
      gmail: 'move to Trash',
      microsoft: 'move to Deleted Items',
      fastmail: 'move to Trash',
    },
    flag: { gmail: 'star', microsoft: 'flag', fastmail: 'keyword $flagged' },
    unflag: {
      gmail: 'remove star',
      microsoft: 'remove flag',
      fastmail: 'remove $flagged',
    },
    addLabel: { gmail: 'label', microsoft: 'category', fastmail: 'keyword' },
    removeLabel: {
      gmail: 'remove label',
      microsoft: 'remove category',
      fastmail: 'remove keyword',
    },
  };
  const base = words[op.op][provider];
  return 'label' in op ? `${base} ${op.label}` : base;
}
