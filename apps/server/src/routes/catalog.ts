import { Hono } from 'hono';
import { requireRight } from '../auth/middleware';
import type { Catalog } from '../catalog/loadCatalog';
import type { AppEnv } from '../env';

// The bots and skills this server knows, without their full instructions.
export function catalogRoutes(catalog: Catalog) {
  return new Hono<AppEnv>().get('/catalog', requireRight('read'), (c) =>
    c.json({
      bots: [...catalog.bots.values()].map(
        ({ name, displayName, description, model, skills }) => ({
          name,
          displayName,
          description,
          model,
          skills,
        }),
      ),
      skills: [...catalog.skills.values()].map(({ name, description }) => ({
        name,
        description,
      })),
    }),
  );
}
