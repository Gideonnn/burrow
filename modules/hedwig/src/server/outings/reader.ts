import type { OutingRead } from '@burrow/contracts';
import { untrusted } from '@burrow/platform';
import { redact, textOf } from '../facts/rules';
import type { MessageRow } from '../mail-service';
import { type Detected, unique } from './detect';

export const OUTING_SKILL = 'outing-details';

export function readPrompt(message: MessageRow) {
  return [
    'Read this email about an outing.',
    `Received: ${message.receivedAt.toISOString().slice(0, 10)}`,
    `From: ${message.from.name ?? ''} <${message.from.email}>`,
    `Subject: ${redact(message.subject)}`,
    '',
    untrusted('untrusted_email', redact(textOf(message, 6_000))),
  ].join('\n');
}

// Haiku's reading over the rules' guess; the attachments stay the rules'.
export function withRead(found: Detected, read: OutingRead): Detected {
  if (read.about === 'announcement' || read.about === 'other') {
    return { ...found, confidence: 'none' };
  }
  const title = read.title?.trim() || found.title;
  const venue = read.venue ?? found.venue;
  const vendor = read.vendor ?? found.vendor;
  const organiser = read.organiser ?? found.organiser;
  const orderNumber = read.orderNumber ?? found.orderNumber;
  const website =
    read.website && /^https?:\/\//.test(read.website) ? read.website : null;
  return {
    ...found,
    title,
    kind: read.kind ?? found.kind,
    startsAt: local(read.startsAt) ?? found.startsAt,
    endsAt: local(read.endsAt) ?? found.endsAt,
    doorsAt: local(read.doorsAt) ?? found.doorsAt,
    venue,
    address: found.address ?? read.city,
    organiser,
    vendor,
    orderNumber,
    url: found.url ?? website,
    personaliseBy: local(read.personaliseBy) ?? found.personaliseBy,
    aliases: unique([
      title,
      read.kind,
      organiser,
      vendor,
      venue,
      read.city,
      orderNumber,
      ...found.aliases,
    ]),
  };
}

// The server's own time zone, as the rules read dates too.
function local(value: string | null): string | null {
  if (!value) return null;
  const d = new Date(value.length === 10 ? `${value}T00:00` : value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
