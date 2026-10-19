import { describe, expect, it } from 'vitest';
import { encodeHeader, formatAddress, parseAddressList } from './addresses';

describe('parseAddressList', () => {
  it('keeps commas inside quoted names', () => {
    expect(
      parseAddressList('"Doe, Jane" <jane@example.com>, bob@example.com'),
    ).toEqual([
      { name: 'Doe, Jane', email: 'jane@example.com' },
      { email: 'bob@example.com' },
    ]);
  });

  it('returns nothing for a missing header', () => {
    expect(parseAddressList(undefined)).toEqual([]);
  });
});

describe('formatAddress', () => {
  it('quotes names with special characters and encodes non-ASCII names', () => {
    expect(formatAddress({ name: 'Doe, Jane', email: 'j@example.com' })).toBe(
      '"Doe, Jane" <j@example.com>',
    );
    expect(encodeHeader('Zoë')).toBe(
      `=?UTF-8?B?${Buffer.from('Zoë').toString('base64')}?=`,
    );
  });
});
