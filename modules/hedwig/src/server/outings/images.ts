import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';

export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_PAGE_BYTES = 2 * 1024 * 1024;

export type Fetched = { data: Uint8Array; contentType: string; url: string };
// Fetches a URL from the internet for the server; tests pass a fake.
export type FetchPublic = (url: string, maxBytes: number) => Promise<Fetched>;

export type ImageRef =
  | { url: string }
  | { messageId: string; attachmentId: string };
export type ImageCandidate = { source: 'mail' | 'website'; ref: ImageRef };

// Pictures nobody wants above an outing: social media buttons, logos,
// tracking pixels and the like.
const SOCIAL =
  /facebook|instagram|twitter|\bx\.com|tiktok|linkedin|pinterest|whatsapp|snapchat|threads\.net|youtube|youtu\.be|spotify|soundcloud/i;
const NOT_A_PICTURE =
  /logo|icon|badge|pixel|track|beacon|spacer|blank\.|open\.(gif|png)|app-?store|google-?play|button|arrow|divider|signature|avatar|qr/i;

const attr = (tag: string, name: string) => {
  const m = new RegExp(
    String.raw`\b${name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`,
    'i',
  ).exec(tag);
  return m ? decode(m[1] ?? m[2] ?? m[3] ?? '') : undefined;
};
const decode = (s: string) =>
  s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .trim();

// The remote images of a mail worth a look, in the order they appear.
export function mailImages(html: string | null): string[] {
  if (!html) return [];
  const out: string[] = [];
  for (const m of html.matchAll(/<img\b[^>]*>/gi)) {
    const tag = m[0];
    const src = attr(tag, 'src');
    if (!src || !/^https?:\/\//i.test(src)) continue;
    const width = Number(attr(tag, 'width') ?? NaN);
    const height = Number(attr(tag, 'height') ?? NaN);
    if (width < 200 || height < 100) continue;
    const words = `${src} ${attr(tag, 'alt') ?? ''} ${attr(tag, 'class') ?? ''}`;
    if (SOCIAL.test(words) || NOT_A_PICTURE.test(words)) continue;
    if (SOCIAL.test(linkAround(html, m.index!))) continue;
    if (!out.includes(src)) out.push(src);
  }
  return out;
}

// The href of the link an image sits in, if any.
function linkAround(html: string, at: number): string {
  const before = html.slice(Math.max(0, at - 600), at);
  const open = before.lastIndexOf('<a ');
  if (open < 0 || before.indexOf('</a', open) >= 0) return '';
  return attr(before.slice(open), 'href') ?? '';
}

// The pictures a web page offers for sharing (og:image, twitter:image).
export function pageImages(html: string, base: string): string[] {
  const out: string[] = [];
  for (const m of html.matchAll(/<meta\b[^>]*>/gi)) {
    const key = attr(m[0], 'property') ?? attr(m[0], 'name') ?? '';
    if (!/^(og:image(:secure_url|:url)?|twitter:image(:src)?)$/i.test(key))
      continue;
    const content = attr(m[0], 'content');
    if (!content) continue;
    try {
      const url = new URL(content, base).toString();
      if (/^https?:/.test(url) && !out.includes(url)) out.push(url);
    } catch {
      // not a URL
    }
  }
  return out;
}

const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
export const IMAGE_EXTENSIONS: Record<string, string> = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/gif': '.gif',
  'image/webp': '.webp',
};

// Type and size from the first bytes; anything else (SVG, HTML) is no
// picture to keep.
export function measure(
  data: Uint8Array,
): { contentType: string; width: number; height: number } | null {
  const b = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  if (b.length >= 24 && b.readUInt32BE(0) === 0x89504e47) {
    return {
      contentType: 'image/png',
      width: b.readUInt32BE(16),
      height: b.readUInt32BE(20),
    };
  }
  if (b.length >= 10 && b.toString('ascii', 0, 3) === 'GIF') {
    return {
      contentType: 'image/gif',
      width: b.readUInt16LE(6),
      height: b.readUInt16LE(8),
    };
  }
  if (
    b.length >= 30 &&
    b.toString('ascii', 0, 4) === 'RIFF' &&
    b.toString('ascii', 8, 12) === 'WEBP'
  ) {
    const chunk = b.toString('ascii', 12, 16);
    if (chunk === 'VP8X') {
      return {
        contentType: 'image/webp',
        width: 1 + b.readUIntLE(24, 3),
        height: 1 + b.readUIntLE(27, 3),
      };
    }
    if (chunk === 'VP8 ') {
      return {
        contentType: 'image/webp',
        width: b.readUInt16LE(26) & 0x3fff,
        height: b.readUInt16LE(28) & 0x3fff,
      };
    }
    if (chunk === 'VP8L') {
      const bits = b.readUInt32LE(21);
      return {
        contentType: 'image/webp',
        width: (bits & 0x3fff) + 1,
        height: ((bits >> 14) & 0x3fff) + 1,
      };
    }
    return null;
  }
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) return null;
      const marker = b[i + 1]!;
      const length = b.readUInt16BE(i + 2);
      // Start of frame: baseline, progressive and the rarer kinds.
      if (
        marker >= 0xc0 &&
        marker <= 0xcf &&
        marker !== 0xc4 &&
        marker !== 0xc8 &&
        marker !== 0xcc
      ) {
        return {
          contentType: 'image/jpeg',
          height: b.readUInt16BE(i + 5),
          width: b.readUInt16BE(i + 7),
        };
      }
      i += 2 + length;
    }
  }
  return null;
}

// Good enough to stand above an outing: not a thumbnail, not a sliver.
export function fitsAbove(size: { width: number; height: number }) {
  const ratio = size.width / size.height;
  return size.width >= 300 && size.height >= 150 && ratio <= 5 && ratio >= 0.4;
}

export function isImageType(contentType: string) {
  return IMAGE_TYPES.includes(contentType);
}

// Addresses in the home network and the machine itself; a link in a mail
// must never make the server look there.
const PRIVATE = new BlockList();
for (const [net, prefix] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 3],
] as const) {
  PRIVATE.addSubnet(net, prefix, 'ipv4');
}
for (const [net, prefix] of [
  ['::', 127],
  ['fc00::', 7],
  ['fe80::', 10],
  ['ff00::', 8],
] as const) {
  PRIVATE.addSubnet(net, prefix, 'ipv6');
}

export function isPrivateAddress(ip: string): boolean {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip)?.[1];
  if (mapped) return PRIVATE.check(mapped, 'ipv4');
  const family = isIP(ip);
  if (!family) return true;
  return PRIVATE.check(ip, family === 4 ? 'ipv4' : 'ipv6');
}

// fetch for links from mail and websites: http(s) on the usual ports, public
// addresses only, after every redirect too, and never more than maxBytes.
export const fetchPublic: FetchPublic = async (start, maxBytes) => {
  let url = new URL(start);
  for (let hop = 0; hop < 5; hop++) {
    if (!/^https?:$/.test(url.protocol) || url.username || url.password) {
      throw new Error('only plain http and https links');
    }
    if (url.port && url.port !== '80' && url.port !== '443') {
      throw new Error('only the usual ports');
    }
    const host = url.hostname.replace(/^\[|\]$/g, '');
    const addresses = isIP(host)
      ? [{ address: host }]
      : await lookup(host, { all: true });
    if (
      !addresses.length ||
      addresses.some((a) => isPrivateAddress(a.address))
    ) {
      throw new Error('not a public address');
    }
    const res = await fetch(url, {
      redirect: 'manual',
      signal: AbortSignal.timeout(15_000),
      headers: {
        'user-agent': 'Mozilla/5.0 (compatible; Hedwig)',
        accept: 'image/*,text/html;q=0.8',
      },
    });
    if (res.status >= 300 && res.status < 400) {
      const location = res.headers.get('location');
      await res.body?.cancel();
      if (!location) throw new Error(`redirect without a location`);
      url = new URL(location, url);
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`HTTP ${res.status}`);
    }
    const length = Number(res.headers.get('content-length') ?? 0);
    if (length > maxBytes) {
      await res.body?.cancel();
      throw new Error('too large');
    }
    const chunks: Uint8Array[] = [];
    let size = 0;
    for await (const chunk of res.body ?? []) {
      size += chunk.byteLength;
      if (size > maxBytes) throw new Error('too large');
      chunks.push(chunk);
    }
    return {
      data: Buffer.concat(chunks),
      contentType: (res.headers.get('content-type') ?? '')
        .split(';')[0]!
        .trim()
        .toLowerCase(),
      url: url.toString(),
    };
  }
  throw new Error('too many redirects');
};

export const pageLimit = MAX_PAGE_BYTES;
