import { z } from 'zod';
import { right } from './catalog';
import { mailboxRole, mailProvider } from './mail';
import { settingsValues } from './settings';

export const person = z.object({
  id: z.string(),
  name: z.string().min(1),
});
export type Person = z.infer<typeof person>;

// What a mailbox is for; clients group and merge inboxes by it.

export const mailboxSummary = z.object({
  id: z.string(),
  ownerId: z.string(),
  provider: mailProvider,
  address: z.string(),
  name: z.string(),
  role: mailboxRole,
  // Extra instructions for the bots, for mail in this mailbox only.
  instructions: z.string(),
  // The provider refused the stored login; the owner has to log in again.
  needsReconnect: z.boolean(),
});
export type MailboxSummary = z.infer<typeof mailboxSummary>;

export const meResponse = z.object({
  person,
  key: z.object({ id: z.string(), name: z.string() }),
  rights: z.array(right),
  mailboxes: z.array(mailboxSummary),
  // The language the person's bots write in; null means the server default.
  language: z.string().nullable(),
  // A household admin manages everyone's settings and devices, never content.
  admin: z.boolean(),
  settings: settingsValues,
});
export type MeResponse = z.infer<typeof meResponse>;

export const updateMailboxRequest = z.object({
  name: z.string().trim().min(1).optional(),
  role: mailboxRole.optional(),
  instructions: z.string().max(4000).optional(),
});
export type UpdateMailboxRequest = z.infer<typeof updateMailboxRequest>;

// Every mailbox the key sees, in the order the person wants them.
export const mailboxOrderRequest = z.object({
  ids: z.array(z.string()).min(1).max(100),
});

export const updateMeRequest = z.object({
  language: z.string().trim().min(1).max(40).nullable(),
});

export const createPersonRequest = z.object({ name: z.string().trim().min(1) });

// Limits a key to part of its person's things, per module, e.g.
// { mailboxes: [id] }. An absent entry means everything of that kind.
export const keyRestrictions = z.record(z.string(), z.array(z.string()));
export type KeyRestrictions = z.infer<typeof keyRestrictions>;

export const apiKeySummary = z.object({
  id: z.string(),
  personId: z.string(),
  name: z.string(),
  prefix: z.string(),
  rights: z.array(right),
  restrictions: keyRestrictions,
  // The key reads facts about content (category, summary, names) but never
  // the content itself.
  factsOnly: z.boolean(),
  // restrictions.mailboxes, kept for older clients.
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
  restrictions: keyRestrictions.default({}),
  factsOnly: z.boolean().default(false),
});
export type CreateKeyRequest = z.infer<typeof createKeyRequest>;

export const createKeyResponse = z.object({
  key: apiKeySummary,
  // Shown once; the server keeps only a hash.
  token: z.string(),
});
export type CreateKeyResponse = z.infer<typeof createKeyResponse>;

// A person as household admins see them: settings and devices, no content.
export const householdMember = z.object({
  id: z.string(),
  name: z.string(),
  email: z.string().nullable(),
  admin: z.boolean(),
  settings: settingsValues,
  keys: z.array(apiKeySummary),
});
export type HouseholdMember = z.infer<typeof householdMember>;
