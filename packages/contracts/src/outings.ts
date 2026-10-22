import { z } from 'zod';
import { address } from './mail';

// An outing (Evenement in the apps): a concert, play, festival or party the
// household goes to. Outings are shared by everyone in the household, unlike
// mail; tickets are sensitive and never go to a cloud model.

const text = (max: number) => z.string().trim().max(max);
const optionalText = (max: number) => text(max).min(1).nullable();

export const personRef = z.object({ id: z.string(), name: z.string() });
export type PersonRef = z.infer<typeof personRef>;

export const outingTicket = z.object({
  id: z.string(),
  name: z.string(),
  contentType: z.string(),
  size: z.number().int().nonnegative(),
  holder: z.string().nullable(),
  personalised: z.boolean(),
  // The mail it came from, when it came from one.
  messageId: z.string().nullable(),
  addedBy: personRef,
  addedAt: z.iso.datetime(),
});
export type OutingTicket = z.infer<typeof outingTicket>;

// A checklist item. `personalise` comes from a deadline in the mail,
// `calendar` closes when the outing is in the shared calendar.
export const outingTaskKind = z.enum(['personalise', 'calendar', 'custom']);
export const outingTask = z.object({
  id: z.string(),
  kind: outingTaskKind,
  title: z.string(),
  dueAt: z.iso.datetime().nullable(),
  assignee: personRef.nullable(),
  doneAt: z.iso.datetime().nullable(),
  doneBy: personRef.nullable(),
});
export type OutingTask = z.infer<typeof outingTask>;

// A mail about the outing. Someone else's mail shows only that it exists.
export const outingMail = z.object({
  id: z.string(),
  visible: z.boolean(),
  owner: personRef,
  subject: z.string().nullable(),
  from: address.nullable(),
  receivedAt: z.iso.datetime(),
});
export type OutingMail = z.infer<typeof outingMail>;

const outingFields = {
  title: text(200).min(1),
  // "concert", "90's party", "festival": free text, also a search word.
  kind: optionalText(60),
  startsAt: z.iso.datetime(),
  endsAt: z.iso.datetime().nullable(),
  doorsAt: z.iso.datetime().nullable(),
  allDay: z.boolean(),
  venue: optionalText(200),
  address: optionalText(300),
  organiser: optionalText(200),
  vendor: optionalText(100),
  orderNumber: optionalText(100),
  url: z.url().max(2000).nullable(),
  notes: text(5000),
  // Extra names the outing is found by in mail search.
  aliases: z.array(text(100).min(1)).max(20),
};

export const outing = z.object({
  id: z.string(),
  ...outingFields,
  // Set once calendar sync has put it in the shared calendar.
  inCalendar: z.boolean(),
  tickets: z.array(outingTicket),
  tasks: z.array(outingTask),
  mails: z.array(outingMail),
  createdBy: personRef,
  createdAt: z.iso.datetime(),
  updatedBy: personRef,
  updatedAt: z.iso.datetime(),
});
export type Outing = z.infer<typeof outing>;
export const outingsResponse = z.array(outing);

export const createOutingRequest = z.object({
  title: outingFields.title,
  startsAt: outingFields.startsAt,
  kind: outingFields.kind.optional(),
  endsAt: outingFields.endsAt.optional(),
  doorsAt: outingFields.doorsAt.optional(),
  allDay: outingFields.allDay.optional(),
  venue: outingFields.venue.optional(),
  address: outingFields.address.optional(),
  organiser: outingFields.organiser.optional(),
  vendor: outingFields.vendor.optional(),
  orderNumber: outingFields.orderNumber.optional(),
  url: outingFields.url.optional(),
  notes: outingFields.notes.optional(),
  aliases: outingFields.aliases.optional(),
  personaliseBy: z.iso.datetime().nullable().optional(),
  // Made from a mail: link it and keep these attachments as tickets.
  messageId: z.string().optional(),
  attachmentIds: z.array(z.string()).max(20).optional(),
});
export type CreateOutingRequest = z.infer<typeof createOutingRequest>;

export const updateOutingRequest = z
  .object({ ...outingFields, inCalendar: z.boolean() })
  .partial();
export type UpdateOutingRequest = z.infer<typeof updateOutingRequest>;

// What Hedwig reads from a mail before the person makes it an outing; every
// field can still be changed.
export const outingSuggestion = z.object({
  // The outing this mail already belongs to.
  outingId: z.string().nullable(),
  title: z.string().nullable(),
  kind: z.string().nullable(),
  startsAt: z.iso.datetime().nullable(),
  endsAt: z.iso.datetime().nullable(),
  doorsAt: z.iso.datetime().nullable(),
  venue: z.string().nullable(),
  address: z.string().nullable(),
  organiser: z.string().nullable(),
  vendor: z.string().nullable(),
  orderNumber: z.string().nullable(),
  url: z.string().nullable(),
  personaliseBy: z.iso.datetime().nullable(),
  aliases: z.array(z.string()),
  // Attachments that look like tickets: pdf, Wallet pass or image.
  tickets: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      contentType: z.string(),
      size: z.number().int(),
    }),
  ),
  // How sure Hedwig is that this mail is about an outing.
  confidence: z.enum(['structured', 'likely', 'none']),
});
export type OutingSuggestion = z.infer<typeof outingSuggestion>;

export const addTicketRequest = z.union([
  z.object({ uploadId: z.string(), name: text(200).min(1) }),
  z.object({ messageId: z.string(), attachmentId: z.string() }),
]);
export type AddTicketRequest = z.infer<typeof addTicketRequest>;

export const updateTicketRequest = z
  .object({ holder: optionalText(100), personalised: z.boolean() })
  .partial();

export const createOutingTaskRequest = z.object({
  title: text(200).min(1),
  dueAt: z.iso.datetime().nullable().optional(),
  assigneeId: z.string().nullable().optional(),
});
export const updateOutingTaskRequest = z
  .object({
    title: text(200).min(1),
    dueAt: z.iso.datetime().nullable(),
    assigneeId: z.string().nullable(),
    done: z.boolean(),
  })
  .partial();

export const linkMailRequest = z.object({ messageId: z.string() });
