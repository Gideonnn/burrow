import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import {
  type BotDefinition,
  botDefinition,
  type SkillDefinition,
  skillDefinition,
} from '@burrow/contracts';
import { splitFrontMatter } from './frontMatter';

export type Catalog = {
  bots: Map<string, BotDefinition>;
  skills: Map<string, SkillDefinition>;
};

export type CatalogDirs = {
  bots: string[];
  skills: string[];
};

// Later directories override earlier ones by name, so a personal directory on
// the server can replace a default bot from the repository.
export async function loadCatalog(dirs: CatalogDirs): Promise<Catalog> {
  const skills = new Map<string, SkillDefinition>();
  for (const dir of dirs.skills) {
    for (const entry of await listDir(dir)) {
      if (!entry.isDirectory()) continue;
      const file = join(dir, entry.name, 'SKILL.md');
      const skill = await parseFile(file, (data, body) =>
        skillDefinition.parse({ ...data, instructions: body }),
      );
      if (skill.name !== entry.name) {
        throw new Error(`${file}: name "${skill.name}" must match its folder`);
      }
      skills.set(skill.name, skill);
    }
  }

  const bots = new Map<string, BotDefinition>();
  for (const dir of dirs.bots) {
    for (const entry of await listDir(dir)) {
      if (!entry.isFile() || !entry.name.endsWith('.md')) continue;
      const file = join(dir, entry.name);
      const bot = await parseFile(file, (data, body) =>
        botDefinition.parse({ ...data, persona: body }),
      );
      if (`${bot.name}.md` !== entry.name) {
        throw new Error(`${file}: name "${bot.name}" must match the file name`);
      }
      bots.set(bot.name, bot);
    }
  }

  for (const bot of bots.values()) {
    for (const skill of bot.skills) {
      if (!skills.has(skill)) {
        throw new Error(`bot "${bot.name}" uses unknown skill "${skill}"`);
      }
    }
  }

  return { bots, skills };
}

async function listDir(dir: string) {
  try {
    return await readdir(dir, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
}

async function parseFile<T>(
  file: string,
  build: (data: Record<string, unknown>, body: string) => T,
): Promise<T> {
  try {
    const { data, body } = splitFrontMatter(await readFile(file, 'utf8'));
    return build(data, body);
  } catch (error) {
    throw new Error(`${file}: ${(error as Error).message}`, { cause: error });
  }
}
