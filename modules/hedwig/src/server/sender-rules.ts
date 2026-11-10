import type { Address, RuleKind } from '@burrow/contracts';
import type { ProviderMessage } from '../provider';

// Mail from these is written by people, so one bad address never condemns
// the domain.
const FREE_MAIL = new Set([
  'gmail.com',
  'googlemail.com',
  'outlook.com',
  'hotmail.com',
  'live.com',
  'msn.com',
  'icloud.com',
  'me.com',
  'mac.com',
  'yahoo.com',
  'ymail.com',
  'aol.com',
  'proton.me',
  'protonmail.com',
  'pm.me',
  'gmx.com',
  'gmx.net',
  'gmx.de',
  'web.de',
  'fastmail.com',
  'hey.com',
  'zoho.com',
  'mail.com',
  'hotmail.nl',
  'live.nl',
  'outlook.nl',
  'hetnet.nl',
  'ziggo.nl',
  'kpnmail.nl',
  'kpnplanet.nl',
  'planet.nl',
  'home.nl',
  'xs4all.nl',
  'telfort.nl',
  'upcmail.nl',
  'chello.nl',
  'casema.nl',
  'tele2.nl',
  'zeelandnet.nl',
  'quicknet.nl',
]);

export type RuleScope = 'address' | 'domain';

// Bulk mail (it carries List-Unsubscribe) comes from many addresses on one
// sending host, so a spam verdict covers that exact host; anything else, and
// free-mail hosts always, only the address.
export function ruleTarget(message: {
  from: Address;
  headers: ProviderMessage['headers'];
}): [string, RuleScope] {
  const address = message.from.email.toLowerCase();
  const domain = address.slice(address.lastIndexOf('@') + 1);
  const bulk = Boolean(message.headers.listUnsubscribe);
  return bulk && domain && !FREE_MAIL.has(domain)
    ? [domain, 'domain']
    : [address, 'address'];
}

export function authenticationFailed(
  headers: ProviderMessage['headers'],
): boolean {
  return /\b(spf|dkim|dmarc)=fail\b/i.test(headers.authenticationResults ?? '');
}

// The reason in the triage log when a rule decided instead of the bot, in the
// owner's language (a name such as "Dutch"); only Dutch and English for now.
export function senderReason(
  kind: RuleKind,
  sender: string,
  language: string,
): string {
  const dutch = /^(dutch|nederlands|nl)\b/i.test(language.trim());
  if (kind === 'spam')
    return dutch
      ? `Je hebt mail van ${sender} eerder als spam gemarkeerd.`
      : `You marked mail from ${sender} as spam before.`;
  return dutch
    ? `Je hebt gezegd dat mail van ${sender} geen spam is.`
    : `You said mail from ${sender} is not spam.`;
}
