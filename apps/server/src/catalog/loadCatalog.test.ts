import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadCatalog } from './loadCatalog';

const repo = resolve(import.meta.dirname, '../../../..');

let tmp: string;
beforeEach(async () => {
  tmp = await mkdtemp(join(tmpdir(), 'burrow-catalog-'));
  await mkdir(join(tmp, 'bots'));
  await mkdir(join(tmp, 'skills/tidy'), { recursive: true });
  await writeFile(
    join(tmp, 'skills/tidy/SKILL.md'),
    '---\nname: tidy\ndescription: Tidies up.\n---\nPut things away.\n',
  );
});
afterEach(() => rm(tmp, { recursive: true, force: true }));

const bot = (front: string) => `---\n${front}\n---\nA helpful elf.\n`;
const dirs = () => ({
  bots: [join(tmp, 'bots')],
  skills: [join(tmp, 'skills')],
});

describe('loadCatalog', () => {
  it('loads the bots and skills shipped in the repository', async () => {
    const catalog = await loadCatalog({
      bots: [join(repo, 'bots')],
      skills: [join(repo, 'skills')],
    });
    const kreacher = catalog.bots.get('kreacher');
    expect(kreacher?.displayName).toBe('Kreacher');
    expect(kreacher?.skills).toContain('sorting-hat');
    expect(catalog.skills.get('sorting-hat')?.instructions).toMatch(
      /untrusted/i,
    );
  });

  it('applies defaults and keeps the body as the persona', async () => {
    await writeFile(
      join(tmp, 'bots/winky.md'),
      bot('name: winky\ndisplayName: Winky\ndescription: Helps.'),
    );
    const winky = (await loadCatalog(dirs())).bots.get('winky');
    expect(winky).toMatchObject({
      model: 'haiku',
      rights: ['read'],
      skills: [],
      persona: 'A helpful elf.',
    });
  });

  it('refuses a bot that asks for the right to send mail', async () => {
    await writeFile(
      join(tmp, 'bots/winky.md'),
      bot(
        'name: winky\ndisplayName: Winky\ndescription: Helps.\nrights: [read, send]',
      ),
    );
    await expect(loadCatalog(dirs())).rejects.toThrow(/winky\.md/);
  });

  it('refuses a bot that uses a skill that does not exist', async () => {
    await writeFile(
      join(tmp, 'bots/winky.md'),
      bot(
        'name: winky\ndisplayName: Winky\ndescription: Helps.\nskills: [cooking]',
      ),
    );
    await expect(loadCatalog(dirs())).rejects.toThrow(
      /unknown skill "cooking"/,
    );
  });

  it('lets a later directory replace a bot with the same name', async () => {
    const personal = join(tmp, 'personal');
    await mkdir(personal);
    await writeFile(
      join(tmp, 'bots/winky.md'),
      bot('name: winky\ndisplayName: Winky\ndescription: Default.'),
    );
    await writeFile(
      join(personal, 'winky.md'),
      bot('name: winky\ndisplayName: Winky\ndescription: Personal.'),
    );
    const catalog = await loadCatalog({
      ...dirs(),
      bots: [join(tmp, 'bots'), personal],
    });
    expect(catalog.bots.get('winky')?.description).toBe('Personal.');
  });

  it('treats a missing personal directory as empty', async () => {
    const catalog = await loadCatalog({
      bots: [join(tmp, 'nope')],
      skills: [join(tmp, 'nope')],
    });
    expect(catalog.bots.size).toBe(0);
  });
});
