import { describe, expect, it } from 'vitest';
import {
  fetchPublic,
  isPrivateAddress,
  mailImages,
  measure,
  pageImages,
} from './images';

describe('outing pictures', () => {
  it('never lets a link reach the home network or the server itself', async () => {
    for (const ip of [
      '127.0.0.1',
      '10.0.0.8',
      '192.168.1.1',
      '172.20.0.1',
      '169.254.169.254',
      '::1',
      '::ffff:192.168.1.1',
      'fe80::1',
      'fd00::1',
    ]) {
      expect(isPrivateAddress(ip), ip).toBe(true);
    }
    expect(isPrivateAddress('93.184.216.34')).toBe(false);
    expect(isPrivateAddress('2606:2800:220:1::1')).toBe(false);
    await expect(fetchPublic('http://127.0.0.1/', 100)).rejects.toThrow(
      'not a public address',
    );
    await expect(fetchPublic('http://localhost:4717/', 100)).rejects.toThrow(
      'only the usual ports',
    );
    await expect(fetchPublic('file:///etc/passwd', 100)).rejects.toThrow(
      'only plain http and https',
    );
  });

  it('skips logos, pixels and social buttons in a mail', () => {
    const html = `
      <img src="https://cdn.example.com/brand-logo.png">
      <img src="https://cdn.example.com/t.gif" width="1" height="1">
      <a href="https://instagram.com/neon"><img src="https://cdn.example.com/a.png"></a>
      <img src="https://cdn.example.com/youtube.png">
      <img src="cid:part1">
      <img src="https://cdn.example.com/neon.jpg?w=1200&amp;h=600">`;
    expect(mailImages(html)).toEqual([
      'https://cdn.example.com/neon.jpg?w=1200&h=600',
    ]);
  });

  it("reads a page's share picture, relative or not", () => {
    const html = `<meta content="/a.jpg" property="og:image">
      <meta name="twitter:image" content="https://img.example.com/b.png">`;
    expect(pageImages(html, 'https://neon.example.com/tickets')).toEqual([
      'https://neon.example.com/a.jpg',
      'https://img.example.com/b.png',
    ]);
  });

  it('knows a picture by its bytes, and SVG is none', () => {
    const png = Buffer.alloc(24);
    png.writeUInt32BE(0x89504e47, 0);
    png.writeUInt32BE(1200, 16);
    png.writeUInt32BE(630, 20);
    expect(measure(png)).toEqual({
      contentType: 'image/png',
      width: 1200,
      height: 630,
    });
    expect(
      measure(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>')),
    ).toBeNull();
  });
});
