import { z } from 'zod';
import { right } from './catalog';
import { mailProvider } from './mail';

export const person = z.object({
  id: z.string(),
  name: z.string().min(1),
});
export type Person = z.infer<typeof person>;

export const mailboxSummary = z.object({
  id: z.string(),
  ownerId: z.string(),
  provider: mailProvider,
  address: z.string(),
  name: z.string(),
});
export type MailboxSummary = z.infer<typeof mailboxSummary>;

export const meResponse = z.object({
  person,
  key: z.object({ id: z.string(), name: z.string() }),
  rights: z.array(right),
  mailboxes: z.array(mailboxSummary),
});
export type MeResponse = z.infer<typeof meResponse>;

export const createPersonRequest = z.object({ name: z.string().trim().min(1) });

export const apiKeySummary = z.object({
  id: z.string(),
  personId: z.string(),
  name: z.string(),
  prefix: z.string(),
  rights: z.array(right),
  mailboxIds: z.array(z.string()).nullable(),
  lastUsedAt: z.iso.datetime().nullable(),
  revokedAt: z.iso.datetime().nullable(),
});
export type ApiKeySummary = z.infer<typeof apiKeySummary>;

export const createKeyRequest = z.object({
  personId: z.string(),
  name: z.string().trim().min(1),
  rights: z.array(right).min(1),
  // null: every mailbox of the person, including future ones.
  mailboxIds: z.array(z.string()).nullable().default(null),
});
export type CreateKeyRequest = z.infer<typeof createKeyRequest>;

export const createKeyResponse = z.object({
  key: apiKeySummary,
  // Shown once; the server keeps only a hash.
  token: z.string(),
});
export type CreateKeyResponse = z.infer<typeof createKeyResponse>;
