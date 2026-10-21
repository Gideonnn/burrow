import { describe, expect, it } from 'vitest';
import {
  automated,
  noise,
  redact,
  redactCodes,
  sensitiveKinds,
  subjectPattern,
  textOf,
} from './rules';

// Invented values: the textbook example IBAN and a BSN that passes the
// eleven test.
const IBAN = 'NL91ABNA0417164300';
const BSN = '111222333';
const githubToken = `ghp_${'a1B2'.repeat(9)}`;

describe('sensitive', () => {
  it('finds secrets and personal numbers, never their values', () => {
    expect(sensitiveKinds(`Je token: ${githubToken}`)).toEqual([
      'github-token',
    ]);
    expect(sensitiveKinds(`Stort op NL91 ABNA 0417 1643 00 graag`)).toEqual([
      'iban',
    ]);
    expect(sensitiveKinds(`Mijn BSN is ${BSN}.`)).toEqual(['bsn']);
  });

  it('ignores numbers that fail the checks', () => {
    expect(sensitiveKinds('Stort op NL91ABNA0417164301')).toEqual([]);
    expect(sensitiveKinds(`Ordernummer ${BSN}`)).toEqual([]);
    expect(sensitiveKinds('BSN 123456789')).toEqual([]);
  });

  it('redacts what it finds', () => {
    const text = redact(
      `IBAN ${IBAN}, BSN ${BSN}, token ${githubToken}, rest blijft`,
    );
    expect(text).toBe(
      'IBAN [iban], BSN [bsn], token [secret: github-token], rest blijft',
    );
    expect(redactCodes('Je code is 482913, zie https://example.com/x')).toBe(
      'Je code is [code], zie [link]',
    );
  });
});

describe('noise', () => {
  it('spots login codes and account notices', () => {
    expect(noise('Je verificatiecode', 'Gebruik 482913 om in te loggen')).toBe(
      'code',
    );
    expect(noise('Reset your password', 'Click the link')).toBe('account');
    expect(noise('Factuur oktober', 'Bedrag € 12,50')).toBeNull();
  });
});

describe('templates', () => {
  it('replaces numbers, dates and amounts in the subject', () => {
    expect(subjectPattern('Je verificatiecode is 482913')).toBe(
      'je verificatiecode is #',
    );
    expect(subjectPattern('Factuur 2026-0042 van € 12,50 op 3-10-2026')).toBe(
      'factuur # van <amount> op <date>',
    );
  });

  it('only groups mail a service sends, not replies or forwards', () => {
    const base = { headers: {}, subject: 'Je bestelling' };
    expect(
      automated({ ...base, from: { email: 'noreply@shop.example' } }),
    ).toBe(true);
    expect(automated({ ...base, from: { email: 'eva@example.com' } })).toBe(
      false,
    );
    expect(
      automated({
        ...base,
        subject: 'Fwd: Je bestelling',
        from: { email: 'noreply@shop.example' },
      }),
    ).toBe(false);
  });
});

describe('textOf', () => {
  it('drops quoted replies and falls back to the html', () => {
    expect(
      textOf({
        bodyText: 'Prima!\n\nOp 1 okt. 2026 schreef Eva:\n> eerder',
        bodyHtml: null,
        snippet: '',
      }),
    ).toBe('Prima!');
    expect(
      textOf({
        bodyText: null,
        bodyHtml: '<p>Hallo <b>daar</b></p>',
        snippet: '',
      }),
    ).toBe('Hallo daar');
  });
});
