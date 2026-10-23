import type { Address, Recipients } from '@burrow/contracts';

type Original = {
  from: Address;
  to: Address[];
  cc: Address[];
  // Null for mail stored before Reply-To was kept.
  replyTo: Address[] | null;
};

// The one rule for who a reply goes to, used by Hedwig's Reply buttons (through
// the message detail), drafts, MCP and routines. Reply answers Reply-To, else the
// sender; Reply all adds the original To and keeps Cc in Cc. The owner's own
// addresses and doubles drop out, compared without case. On mail the owner sent,
// Reply goes to its recipients, as in Apple Mail.
export function replyRecipients(
  original: Original,
  own: string[],
  all: boolean,
): Recipients {
  const skip = new Set(own.map((email) => email.toLowerCase()));
  const keep = (list: Address[]) =>
    list.filter((address) => {
      const key = address.email.toLowerCase();
      if (skip.has(key)) return false;
      skip.add(key);
      return true;
    });
  let to = keep(original.replyTo?.length ? original.replyTo : [original.from]);
  if (all || !to.length) to.push(...keep(original.to));
  let cc = all ? keep(original.cc) : [];
  if (!to.length) [to, cc] = [cc, []];
  if (!to.length) to = [original.from];
  return { to, cc };
}
