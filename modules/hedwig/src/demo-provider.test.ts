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

  it('gives every demo message that says it has attachments files to download', async () => {
    for (const seed of DEMO_SEEDS) {
      const demo = new DemoProvider(seed, 'demo@example.com');
      for (const m of (await demo.sync(null)).upserts) {
        const files = await demo.attachments(m.providerId);
        expect(files.length > 0).toBe(m.hasAttachments);
        for (const file of files) {
          const data = await demo.attachment(m.providerId, file.id);
          expect(data.byteLength).toBe(file.size);
          if (file.contentType === 'application/pdf') {
            const text = Buffer.from(data).toString('latin1');
            expect(text.startsWith('%PDF-1.4')).toBe(true);
            const xref = Number(text.match(/startxref\n(\d+)/)?.[1]);
            expect(text.slice(xref, xref + 4)).toBe('xref');
          }
        }
      }
    }
    const invoices = new DemoProvider('invoices', 'demo@example.com');
    const invoice = [...invoices.messages.values()].find((m) =>
      m.subject.includes('factuur'),
    )!;
    expect(await invoices.attachments(invoice.providerId)).toMatchObject([
      { name: 'factuur-oktober.pdf', contentType: 'application/pdf' },
    ]);
  });
});
