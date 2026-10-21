import { htmlToText } from '../../html';
import type { MessageRow } from '../mail-service';

// Bump when a rule changes, so every message is checked again.
export const RULES_VERSION = 1;

const SECRETS: Record<string, RegExp> = {
  'anthropic-key': /\bsk-ant-[A-Za-z0-9_-]{20,}/g,
  'openai-key': /\bsk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{20,}/g,
  'github-token':
    /\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,})/g,
  'aws-key': /\bAKIA[0-9A-Z]{16}\b/g,
  'slack-token': /\bxox[abprs]-[A-Za-z0-9-]{10,}/g,
  'stripe-key': /\b[sr]k_live_[A-Za-z0-9]{20,}/g,
  'google-key': /\bAIza[0-9A-Za-z_-]{35}\b/g,
  'private-key':
    /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g,
};
const IBAN = /\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b/g;
const NINE_DIGITS = /\b\d{9}\b/g;
const BSN_WORD = /\bbsn\b|burgerservicenummer/i;

const CODE_WORDS =
  /verificatiecode|inlogcode|beveiligingscode|eenmalige code|bevestigingscode|verification code|security code|login code|sign-in code|one-time (?:pass)?code|your code|je code|uw code|\bOTP\b|2FA/i;
const ACCOUNT_WORDS =
  /reset your password|wachtwoord (?:opnieuw instellen|wijzigen|herstellen)|new sign-in|nieuwe aanmelding|nieuw apparaat|new device|sign-in attempt|inlogpoging|security alert|beveiligingsmelding|confirm your email|bevestig je e-?mail/i;
const SHORT_CODE = /\b\d{4,8}\b|\b[A-Z0-9]{3}-[A-Z0-9]{3}\b/;
const AUTOMATED_SENDER =
  /no-?reply|do-?not-?reply|notifications?@|mailer|bounce|info@|news(?:letter)?@|hello@/i;
const REPLY_OR_FORWARD = /^\s*(?:re|antw|fw|fwd|doorst)\s*:/i;

// mod-97 over the rearranged number, digit by digit so it fits a double.
function validIban(raw: string): boolean {
  const iban = raw.replace(/ /g, '');
  if (iban.length < 15 || iban.length > 34) return false;
  let rest = 0;
  for (const c of iban.slice(4) + iban.slice(0, 4)) {
    const value = Number.parseInt(c, 36);
    if (Number.isNaN(value)) return false;
    rest = Number(`${rest}${value}`) % 97;
  }
  return rest === 1;
}

// The Dutch eleven test for a BSN.
function validBsn(digits: string): boolean {
  const weights = [9, 8, 7, 6, 5, 4, 3, 2, -1];
  const sum = [...digits].reduce((s, d, i) => s + Number(d) * weights[i]!, 0);
  return sum % 11 === 0 && sum !== 0;
}

const ibans = (text: string) =>
  [...text.matchAll(IBAN)].map((m) => m[0]).filter(validIban);
const bsns = (text: string) =>
  BSN_WORD.test(text)
    ? [...text.matchAll(NINE_DIGITS)].map((m) => m[0]).filter(validBsn)
    : [];

// The kinds of secrets and personal numbers in a text, never the values.
export function sensitiveKinds(text: string): string[] {
  const kinds = Object.entries(SECRETS)
    .filter(([, pattern]) => new RegExp(pattern.source).test(text))
    .map(([kind]) => kind);
  if (ibans(text).length) kinds.push('iban');
  if (bsns(text).length) kinds.push('bsn');
  return kinds;
}

// The text with secrets and personal numbers replaced, for anything that
// leaves for a cloud AI.
export function redact(text: string): string {
  let out = text;
  for (const [kind, pattern] of Object.entries(SECRETS)) {
    out = out.replace(pattern, `[secret: ${kind}]`);
  }
  for (const iban of ibans(out)) out = out.replaceAll(iban, '[iban]');
  for (const bsn of bsns(out)) out = out.replaceAll(bsn, '[bsn]');
  return out;
}

// Login codes and account notices, which nobody searches for later.
export function noise(
  subject: string,
  text: string,
): 'code' | 'account' | null {
  const head = `${subject}\n${text.slice(0, 600)}`;
  if (CODE_WORDS.test(head) && SHORT_CODE.test(head)) return 'code';
  if (ACCOUNT_WORDS.test(head)) return 'account';
  return null;
}

// Mail a service sends again and again, never mail between people.
export function automated(m: Pick<MessageRow, 'from' | 'subject' | 'headers'>) {
  if (REPLY_OR_FORWARD.test(m.subject)) return false;
  return (
    AUTOMATED_SENDER.test(m.from.email) || Boolean(m.headers.listUnsubscribe)
  );
}

// The subject with numbers, dates, amounts and codes as placeholders:
// "Je verificatiecode is 482913" becomes "je verificatiecode is #".
export function subjectPattern(subject: string): string {
  return subject
    .replace(/[€$£]\s?\d[\d.,]*|\d[\d.,]*\s?(?:EUR|euro)/gi, '<amount>')
    .replace(/\b\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}\b/g, '<date>')
    .replace(/\b[A-Z0-9]*\d[A-Z0-9-]{3,}\b/g, '#')
    .replace(/\d+/g, '#')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

export function templateKey(
  m: Pick<MessageRow, 'from' | 'subject' | 'headers'>,
): string | null {
  return automated(m)
    ? `${m.from.email.toLowerCase()}|${subjectPattern(m.subject)}`
    : null;
}

// The readable text of a message without quoted replies, as a model reads it.
export function textOf(
  m: Pick<MessageRow, 'bodyText' | 'bodyHtml' | 'snippet'>,
  max = 4_000,
): string {
  const body =
    m.bodyText?.trim() || (m.bodyHtml ? htmlToText(m.bodyHtml) : m.snippet);
  const lines: string[] = [];
  for (const line of body.split('\n')) {
    if (
      line.trimStart().startsWith('>') ||
      /^(On|Op) .+(wrote|schreef)\b.*:$/.test(line.trim())
    ) {
      break;
    }
    lines.push(line);
  }
  return lines
    .join('\n')
    .replace(/[ \t]+/g, ' ')
    .replace(/\s+\n/g, '\n')
    .trim()
    .slice(0, max);
}

// Codes in template examples, so Haiku never sees one.
export function redactCodes(text: string): string {
  return redact(text)
    .replace(/\b\d{4,8}\b/g, '[code]')
    .replace(/https?:\/\/\S+/g, '[link]');
}
