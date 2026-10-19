import { describe, expect, it } from 'vitest';
import { DEMO_SEEDS, DemoProvider } from './demo-provider';

describe('DemoProvider', () => {
  it('fills every seed with invented inbox mail addressed to the demo mailbox', async () => {
    for (const seed of DEMO_SEEDS) {
      const { upserts } = await new DemoProvider(seed, 'demo@example.com').sync(
        null,
      );
      expect(upserts.length).toBeGreaterThan(0);
      for (const m of upserts) {
        expect(m.folder).toBe('inbox');
        expect(m.to).toEqual([{ email: 'demo@example.com' }]);
        expect(m.from.email).toMatch(/\.(example|example\.nl)$|@example\.nl$/);
      }
    }
  });

  it('keeps state between calls, like a real mailbox', async () => {
    const demo = new DemoProvider('personal', 'demo@example.com');
    const { upserts, cursor } = await demo.sync(null);
    await demo.apply(upserts[0]!.providerId, [{ op: 'archive' }]);
    expect((await demo.sync(cursor)).upserts).toEqual([]);
    expect(demo.messages.get(upserts[0]!.providerId)?.folder).toBe('archive');
  });
});
