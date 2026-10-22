import { randomUUID } from 'node:crypto';
import { encodeHeader, formatAddress } from './addresses';
import type { OutgoingMessage } from './provider';

// A plain-text RFC 5322 message, for providers that send raw MIME (Gmail).
export function buildMime(message: OutgoingMessage, now = new Date()): string {
  const domain = message.from.email.split('@')[1] ?? 'localhost';
  const headers: [string, string][] = [
    ['From', formatAddress(message.from)],
    ['To', message.to.map(formatAddress).join(', ')],
  ];
  if (message.cc.length)
    headers.push(['Cc', message.cc.map(formatAddress).join(', ')]);
  headers.push(
    ['Subject', encodeHeader(message.subject)],
    ['Date', now.toUTCString().replace('GMT', '+0000')],
    ['Message-ID', `<${randomUUID()}@${domain}>`],
  );
  const parent = message.replyTo?.headers.messageId;
  if (parent) {
    headers.push(['In-Reply-To', parent]);
    const references = [message.replyTo?.headers.references, parent]
      .filter(Boolean)
      .join(' ');
    headers.push(['References', references]);
  }
  headers.push(
    ['MIME-Version', '1.0'],
    ['Content-Type', 'text/plain; charset=UTF-8'],
    ['Content-Transfer-Encoding', 'base64'],
  );
  const body = Buffer.from(message.body, 'utf8')
    .toString('base64')
    .replace(/.{76}/g, '$&\r\n');
  return `${headers.map(([k, v]) => `${k}: ${v}`).join('\r\n')}\r\n\r\n${body}\r\n`;
}

// Shown inside the HTML body: the part has a Content-ID the body can refer to
// and is not explicitly marked as an attachment.
export function isInline(
  disposition: string | null | undefined,
  contentId: string | null | undefined,
): boolean {
  return Boolean(contentId) && !/^\s*attachment\b/i.test(disposition ?? '');
}
