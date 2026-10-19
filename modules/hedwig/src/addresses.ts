import type { Address } from '@burrow/contracts';

// Splits a header such as `"Doe, Jane" <jane@example.com>, bob@example.com`
// on the commas that separate addresses, not the ones inside quotes or angle
// brackets.
export function parseAddressList(header: string | undefined): Address[] {
  if (!header) return [];
  const parts: string[] = [];
  let current = '';
  let quoted = false;
  let angled = false;
  for (const ch of header) {
    if (ch === '"') quoted = !quoted;
    else if (ch === '<' && !quoted) angled = true;
    else if (ch === '>' && !quoted) angled = false;
    if (ch === ',' && !quoted && !angled) {
      parts.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  parts.push(current);
  return parts
    .map((p) => p.trim())
    .filter(Boolean)
    .map(parseAddress);
}

export function parseAddress(text: string): Address {
  const match = /^(.*?)\s*<([^>]+)>\s*$/.exec(text.trim());
  if (!match) return { email: text.trim() };
  const name = match[1]!
    .trim()
    .replace(/^"(.*)"$/, '$1')
    .trim();
  return name ? { name, email: match[2]!.trim() } : { email: match[2]!.trim() };
}

export function formatAddress(address: Address): string {
  if (!address.name) return address.email;
  return `${encodeHeader(address.name)} <${address.email}>`;
}

// RFC 2047 encoding for non-ASCII header values.
export function encodeHeader(value: string): string {
  // eslint-disable-next-line no-control-regex
  if (/^[\x20-\x7e]*$/.test(value)) {
    return /[",<>@]/.test(value) ? `"${value.replace(/"/g, '\\"')}"` : value;
  }
  return `=?UTF-8?B?${Buffer.from(value, 'utf8').toString('base64')}?=`;
}
