import {
  createKeyRequest,
  createPersonRequest,
  type HouseholdMember,
  instructions,
  type MeResponse,
  updateMeRequest,
  updateSettingsRequest,
} from '@burrow/contracts';
import { zValidator } from '@hono/zod-validator';
import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import type { PlatformEnv } from '../env';
import { requireRight } from '../middleware';
import {
  AccessError,
  createKey,
  createPerson,
  listKeys,
  listPeople,
  person,
  revokeKey,
} from '../people';
import { SettingsError } from '../settings';

const asHttp = (error: unknown): never => {
  if (error instanceof AccessError || error instanceof SettingsError) {
    throw new HTTPException(400, { message: error.message });
  }
  throw error;
};

// The person behind the key, their settings, and the household: both people
// are admins who manage each other's settings and devices, but no route here
// returns anyone's mail or recordings.
export const peopleRoutes = new Hono<PlatformEnv>()
  .get('/me', (c) => {
    const { db, access, platform } = c.var;
    const row = person(db, access.personId)!;
    const settings = platform.settings.values(row.id);
    const language = settings.language;
    return c.json({
      person: { id: row.id, name: row.name },
      key: { id: access.keyId, name: access.keyName },
      rights: [...access.rights],
      mailboxes: [],
      ...Object.assign({}, ...platform.modules.map((m) => m.me?.(access))),
      language: typeof language === 'string' ? language : null,
      admin: row.admin,
      settings,
    } satisfies MeResponse);
  })
  // Kept for older clients; the language is a setting like any other.
  .patch(
    '/me',
    requireRight('organize'),
    zValidator('json', updateMeRequest),
    (c) => {
      const { language } = c.req.valid('json');
      try {
        c.var.platform.settings.update(c.var.access.personId, { language });
      } catch (error) {
        asHttp(error);
      }
      return c.json({ language });
    },
  )
  // Names only, so anyone can pick the other person to share something with.
  .get('/people', requireRight('read'), (c) =>
    c.json(listPeople(c.var.db).map(({ id, name }) => ({ id, name }))),
  )
  .get('/settings/schema', (c) => c.json(c.var.platform.settings.schema()))
  .get('/me/settings', requireRight('read'), (c) =>
    c.json(c.var.platform.settings.values(c.var.access.personId)),
  )
  .patch(
    '/me/settings',
    requireRight('organize'),
    zValidator('json', updateSettingsRequest),
    (c) => {
      try {
        return c.json(
          c.var.platform.settings.update(
            c.var.access.personId,
            c.req.valid('json').values,
          ),
        );
      } catch (error) {
        return asHttp(error);
      }
    },
  )
  // The person's standing instructions for every bot that works for them.
  .get('/instructions', requireRight('read'), (c) =>
    c.json({ text: c.var.platform.instructions(c.var.access.personId) }),
  )
  .put(
    '/instructions',
    requireRight('organize'),
    zValidator('json', instructions),
    (c) => {
      c.var.platform.setInstructions(
        c.var.access.personId,
        c.req.valid('json').text,
      );
      return c.json({ text: c.req.valid('json').text });
    },
  )
  .use('/admin/*', requireRight('admin'))
  .get('/admin/people', (c) => {
    const { db, platform } = c.var;
    const keys = listKeys(db);
    return c.json(
      listPeople(db).map((p): HouseholdMember => ({
        id: p.id,
        name: p.name,
        email: p.email,
        admin: p.admin,
        settings: platform.settings.values(p.id),
        keys: keys.filter((k) => k.personId === p.id),
      })),
    );
  })
  .post('/admin/people', zValidator('json', createPersonRequest), (c) => {
    const { id, name } = createPerson(c.var.db, c.req.valid('json').name);
    return c.json({ id, name }, 201);
  })
  .patch(
    '/admin/people/:id/settings',
    zValidator('json', updateSettingsRequest),
    (c) => {
      const id = c.req.param('id');
      if (!person(c.var.db, id)) {
        throw new HTTPException(404, { message: 'unknown person' });
      }
      const { values } = c.req.valid('json');
      const personal = c.var.platform.settings
        .schema()
        .filter((d) => d.personal && d.key in values);
      if (personal.length && id !== c.var.access.personId) {
        throw new HTTPException(403, {
          message: `only the person changes ${personal.map((d) => d.key).join(', ')}`,
        });
      }
      try {
        return c.json(c.var.platform.settings.update(id, values));
      } catch (error) {
        return asHttp(error);
      }
    },
  )
  .get('/admin/people/:id/instructions', (c) =>
    c.json({ text: c.var.platform.instructions(c.req.param('id')) }),
  )
  .put(
    '/admin/people/:id/instructions',
    zValidator('json', instructions),
    (c) => {
      const id = c.req.param('id');
      if (!person(c.var.db, id)) {
        throw new HTTPException(404, { message: 'unknown person' });
      }
      c.var.platform.setInstructions(id, c.req.valid('json').text);
      return c.json({ text: c.req.valid('json').text });
    },
  )
  .get('/admin/keys', (c) => c.json(listKeys(c.var.db)))
  // An admin makes keys for themselves only: a key for someone else would
  // read their mail. The other person logs in on their own Mac instead.
  .post('/admin/keys', zValidator('json', createKeyRequest), (c) => {
    const request = c.req.valid('json');
    if (request.personId !== c.var.access.personId) {
      throw new HTTPException(403, {
        message: 'a key for someone else is made by logging in on their device',
      });
    }
    try {
      return c.json(
        createKey(c.var.db, request, c.var.platform.restrictionChecks),
        201,
      );
    } catch (error) {
      return asHttp(error);
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
