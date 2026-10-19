import { describe, expect, it } from 'vitest';
import { applyOps, describeOp, reverseOps, serverOpsFor } from './server-ops';

const inbox = {
  folder: 'inbox' as const,
  unread: true,
  flagged: false,
  labels: [],
};

describe('serverOpsFor', () => {
  it('marks filtered mail as read so phones show no badge', () => {
    expect(serverOpsFor({ kind: 'spam' })).toContainEqual({ op: 'markRead' });
    expect(serverOpsFor({ kind: 'archive' })).toContainEqual({
      op: 'markRead',
    });
  });

  it('leaves needs-reply mail unread and flags it', () => {
    expect(serverOpsFor({ kind: 'needs-reply' })).toEqual([{ op: 'flag' }]);
  });

  it('does nothing for keep', () => {
    expect(serverOpsFor({ kind: 'keep' })).toEqual([]);
  });
});

describe('reverseOps', () => {
  it('restores filtered mail to an unread inbox message', () => {
    for (const kind of ['spam', 'archive'] as const) {
      const done = applyOps(inbox, serverOpsFor({ kind }));
      expect(applyOps(done, reverseOps(serverOpsFor({ kind })))).toEqual(inbox);
    }
  });

  it('removes a label the agent added', () => {
    const ops = serverOpsFor({ kind: 'label', label: 'Factuur' });
    const done = applyOps(inbox, ops);
    expect(done.labels).toEqual(['Factuur']);
    expect(applyOps(done, reverseOps(ops)).labels).toEqual([]);
  });
});

describe('applyOps', () => {
  it('does not add a label twice', () => {
    const ops = [
      { op: 'addLabel', label: 'Bon' },
      { op: 'addLabel', label: 'Bon' },
    ] as const;
    expect(applyOps(inbox, [...ops]).labels).toEqual(['Bon']);
  });
});

describe('describeOp', () => {
  it('uses each provider its own spam vocabulary', () => {
    expect(describeOp('gmail', { op: 'moveToSpam' })).toBe('label SPAM');
    expect(describeOp('microsoft', { op: 'moveToSpam' })).toBe(
      'move to Junk Email',
    );
    expect(describeOp('fastmail', { op: 'moveToSpam' })).toBe('move to Junk');
  });

  it('names the label', () => {
    expect(describeOp('microsoft', { op: 'addLabel', label: 'Bon' })).toBe(
      'category Bon',
    );
  });
});
