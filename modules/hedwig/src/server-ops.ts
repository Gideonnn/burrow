import type { MailProvider, TriageAction } from '@burrow/contracts';

// What a triage decision becomes at the provider, so phones using the native
// mail apps see the same result as Hedwig.
export type ServerOp =
  | { op: 'markRead' }
  | { op: 'moveToSpam' }
  | { op: 'archive' }
  | { op: 'flag' }
  | { op: 'addLabel'; label: string };

export function serverOpsFor(action: TriageAction): ServerOp[] {
  switch (action.kind) {
    case 'keep':
      return [];
    case 'spam':
      return [{ op: 'moveToSpam' }, { op: 'markRead' }];
    case 'archive':
      return [{ op: 'archive' }, { op: 'markRead' }];
    case 'needs-reply':
      return [{ op: 'flag' }];
    case 'label':
      return [{ op: 'addLabel', label: action.label }];
  }
}

// Provider vocabulary for each op, used by the provider clients and shown in
// the "what happened on the server" line in the client.
export function describeOp(provider: MailProvider, op: ServerOp): string {
  switch (op.op) {
    case 'markRead':
      return provider === 'fastmail' ? 'keyword $seen' : 'mark as read';
    case 'moveToSpam':
      return {
        gmail: 'label SPAM',
        microsoft: 'move to Junk Email',
        fastmail: 'move to Junk',
      }[provider];
    case 'archive':
      return {
        gmail: 'remove label INBOX',
        microsoft: 'move to Archive',
        fastmail: 'move to Archive',
      }[provider];
    case 'flag':
      return {
        gmail: 'star',
        microsoft: 'flag',
        fastmail: 'keyword $flagged',
      }[provider];
    case 'addLabel':
      return {
        gmail: `label ${op.label}`,
        microsoft: `category ${op.label}`,
        fastmail: `keyword ${op.label}`,
      }[provider];
  }
}
