import { z } from 'zod';

export const mailProvider = z.enum(['gmail', 'microsoft', 'fastmail']);
export type MailProvider = z.infer<typeof mailProvider>;

export const mailbox = z.object({
  id: z.string(),
  owner: z.string(),
  provider: mailProvider,
  address: z.email(),
  name: z.string(),
});
export type Mailbox = z.infer<typeof mailbox>;

export const address = z.object({
  name: z.string().optional(),
  email: z.email(),
});
export type Address = z.infer<typeof address>;

export const message = z.object({
  id: z.string(),
  mailboxId: z.string(),
  providerId: z.string(),
  threadId: z.string().optional(),
  from: address,
  to: z.array(address),
  subject: z.string(),
  snippet: z.string(),
  receivedAt: z.iso.datetime(),
  unread: z.boolean(),
  hasAttachments: z.boolean(),
});
export type Message = z.infer<typeof message>;

// The only things an agent may do to a message. Sending and deleting are
// deliberately absent: mail is untrusted input, so a crafted message can at
// worst make the agent sort it wrongly, never act on the outside world.
export const triageAction = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('keep') }),
  z.object({ kind: z.literal('spam') }),
  z.object({ kind: z.literal('archive') }),
  z.object({ kind: z.literal('needs-reply') }),
  z.object({ kind: z.literal('label'), label: z.string().min(1) }),
]);
export type TriageAction = z.infer<typeof triageAction>;
