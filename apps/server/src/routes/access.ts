import {
  createKeyRequest,
  createPersonRequest,
  type MailboxSummary,
  type MeResponse,
  updateMailboxRequest,
} from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { eq, inArray } from 'drizzle-orm';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import {
  AccessError,
  createKey,
  createPerson,
  listKeys,
  listPeople,
  revokeKey,
} from '../access/service';
import { canSeeMailbox } from '../auth/access';
import { requireRight } from '../auth/middleware';
import { mailboxes, people } from '../db/schema';
import type { AppEnv } from '../env';

const mailboxColumns = {
  id: mailboxes.id,
  ownerId: mailboxes.ownerId,
  provider: mailboxes.provider,
  address: mailboxes.address,
  name: mailboxes.name,
  role: mailboxes.role,
};

export const accessRoutes = new Hono<AppEnv>()
  .get('/me', (c) => {
    const { db, access } = c.var;
    const person = db
      .select({ id: people.id, name: people.name })
      .from(people)
      .where(eq(people.id, access.personId))
      .get()!;
    const boxes = access.mailboxIds.length
      ? db
          .select(mailboxColumns)
          .from(mailboxes)
          .where(inArray(mailboxes.id, [...access.mailboxIds]))
          .orderBy(mailboxes.createdAt, mailboxes.address)
          .all()
      : [];
    return c.json<MeResponse>({
      person,
      key: { id: access.keyId, name: access.keyName },
      rights: [...access.rights],
      mailboxes: boxes,
    });
  })
  // The person renames a mailbox or says what it is for (private, work, school).
  .patch(
    '/mailboxes/:id',
    requireRight('organize'),
    zValidator('json', updateMailboxRequest),
    (c) => {
      const id = c.req.param('id');
      if (!canSeeMailbox(c.var.access, id)) {
        throw new HTTPException(404, { message: 'unknown mailbox' });
      }
      const row = c.var.db
        .update(mailboxes)
        .set(c.req.valid('json'))
        .where(eq(mailboxes.id, id))
        .returning(mailboxColumns)
        .get();
      return c.json<MailboxSummary>(row!);
    },
  )
  .use('/admin/*', requireRight('admin'))
  .get('/admin/people', (c) =>
    c.json(listPeople(c.var.db).map(({ id, name }) => ({ id, name }))),
  )
  .post('/admin/people', zValidator('json', createPersonRequest), (c) => {
    const { id, name } = createPerson(c.var.db, c.req.valid('json').name);
    return c.json({ id, name }, 201);
  })
  // Admin sees which mailboxes exist and who owns them, never their mail.
  .get('/admin/mailboxes', (c) =>
    c.json(c.var.db.select(mailboxColumns).from(mailboxes).all()),
  )
  .get('/admin/keys', (c) => c.json(listKeys(c.var.db)))
  .post('/admin/keys', zValidator('json', createKeyRequest), (c) => {
    try {
      return c.json(createKey(c.var.db, c.req.valid('json')), 201);
    } catch (error) {
      if (error instanceof AccessError) {
        throw new HTTPException(400, { message: error.message });
      }
      throw error;
    }
  })
  .delete('/admin/keys/:id', (c) => {
    const id = c.req.param('id');
    if (id === c.var.access.keyId) {
      throw new HTTPException(400, {
        message: 'revoke this key from another admin key',
      });
    }
    try {
      return c.json(revokeKey(c.var.db, id));
    } catch (error) {
      if (error instanceof AccessError) {
        throw new HTTPException(404, { message: error.message });
      }
      throw error;
    }
  });
