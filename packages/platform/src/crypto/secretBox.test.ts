import { describe, expect, it } from 'vitest';
import { SecretBox } from './secretBox';

describe('SecretBox', () => {
  it('round-trips a value and never stores it in plain text', () => {
    const box = new SecretBox(SecretBox.generateKey());
    const sealed = box.seal({ refreshToken: 'very-secret' });
    expect(sealed).not.toContain('very-secret');
    expect(box.open(sealed)).toEqual({ refreshToken: 'very-secret' });
  });

  it('refuses to open with another key', () => {
    const sealed = new SecretBox(SecretBox.generateKey()).seal('x');
    expect(() => new SecretBox(SecretBox.generateKey()).open(sealed)).toThrow();
  });

  it('detects tampering', () => {
    const box = new SecretBox(SecretBox.generateKey());
    const parts = box.seal('hello').split('.');
    parts[3] = Buffer.from('jello').toString('base64url');
    expect(() => box.open(parts.join('.'))).toThrow();
  });

  it('rejects a key of the wrong length', () => {
    expect(() => new SecretBox(Buffer.alloc(16).toString('base64'))).toThrow(
      /32 bytes/,
    );
  });
});
