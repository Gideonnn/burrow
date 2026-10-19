import { describe, expect, it } from 'vitest';
import { describeOp, serverOpsFor } from './server-ops';

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

describe('describeOp', () => {
  it('uses each provider its own spam vocabulary', () => {
    expect(describeOp('gmail', { op: 'moveToSpam' })).toBe('label SPAM');
    expect(describeOp('microsoft', { op: 'moveToSpam' })).toBe(
      'move to Junk Email',
    );
    expect(describeOp('fastmail', { op: 'moveToSpam' })).toBe('move to Junk');
  });
});
