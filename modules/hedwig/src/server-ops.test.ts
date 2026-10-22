import { describe, expect, it } from 'vitest';
import {
  applyOps,
  describeOp,
  restoreOps,
  reverseOps,
  serverOpsFor,
} from './server-ops';

const inbox = {
  folder: 'inbox' as const,
  unread: true,
  flagged: false,
  labels: [],
};

describe('serverOpsFor', () => {
  it('marks archived mail as read so phones show no badge', () => {
    expect(serverOpsFor({ kind: 'archive' })).toContainEqual({
      op: 'markRead',
    });
  });

  it('leaves spam unread until the person says it is not spam', () => {
    expect(serverOpsFor({ kind: 'spam' })).toEqual([{ op: 'moveToSpam' }]);
  });

  it('leaves needs-reply mail unread and flags it', () => {
    expect(serverOpsFor({ kind: 'needs-reply' })).toEqual([{ op: 'flag' }]);
  });

  it('does nothing for keep', () => {
    expect(serverOpsFor({ kind: 'keep' })).toEqual([]);
  });
});

describe('reverseOps', () => {
  it('restores archived mail to an unread inbox message', () => {
    const ops = serverOpsFor({ kind: 'archive' });
    const done = applyOps(inbox, ops);
    expect(applyOps(done, restoreOps({ kind: 'archive' }, ops))).toEqual(inbox);
  });

  it('restores spam to the inbox as read, also when triage once marked it read', () => {
    for (const ops of [
      serverOpsFor({ kind: 'spam' }),
      [{ op: 'moveToSpam' }, { op: 'markRead' }] as const,
    ]) {
      const done = applyOps(inbox, [...ops]);
      expect(applyOps(done, restoreOps({ kind: 'spam' }, [...ops]))).toEqual({
        ...inbox,
        unread: false,
      });
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
