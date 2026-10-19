import {
  cpSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
import { afterEach, describe, expect, it } from 'vitest';

const migrations = resolve(import.meta.dirname, 'migrations');
const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true });
});

// The migrations folder cut off after `last`, as an older server had it.
function migrationsUpTo(last: string) {
  const dir = mkdtempSync(join(tmpdir(), 'burrow-migrations-'));
  dirs.push(dir);
  cpSync(migrations, dir, { recursive: true });
  const journalFile = join(dir, 'meta/_journal.json');
  const journal = JSON.parse(readFileSync(journalFile, 'utf8')) as {
    entries: { tag: string }[];
  };
  const end = journal.entries.findIndex((e) => e.tag === last);
  journal.entries = journal.entries.slice(0, end + 1);
  writeFileSync(journalFile, JSON.stringify(journal));
  return dir;
}

describe('the platform migration', () => {
  it('keeps keys, languages and routine tasks of an existing household', () => {
    const sqlite = new Database(':memory:');
    const db = drizzle(sqlite);
    migrate(db, {
      migrationsFolder: migrationsUpTo('0008_superb_tiger_shark'),
    });
    sqlite.exec(`
      INSERT INTO people (id, name, language) VALUES ('p1', 'Gideon', 'Dutch'), ('p2', 'Eva', NULL);
      INSERT INTO mailboxes (id, owner_id, provider, address, name, credentials)
        VALUES ('m1', 'p1', 'gmail', 'gideon@example.com', 'Gideon', 'x');
      INSERT INTO api_keys (id, person_id, name, hash, prefix, rights, mailbox_ids)
        VALUES ('k1', 'p1', 'all', 'h1', 'bk_1', '["read"]', NULL),
               ('k2', 'p1', 'one', 'h2', 'bk_2', '["read"]', '["m1"]');
      INSERT INTO messages (id, mailbox_id, provider_id, "from", "to", cc, subject, snippet,
          received_at, folder, unread, flagged, labels, has_attachments, headers)
        VALUES ('msg1', 'm1', 'g1', '{"email":"a@example.com"}', '[]', '[]', 'Hi', 'Hi',
          0, 'inbox', 1, 0, '[]', 0, '{}');
      INSERT INTO routines (id, person_id, name, "trigger", skill, bot, "where", approval, enabled)
        VALUES ('r1', 'p1', 'Facturen', '{"kind":"message"}', 'key-facts', 'kreacher', 'client', 1, 1);
      INSERT INTO tasks (id, routine_id, person_id, message_id, status)
        VALUES ('t1', 'r1', 'p1', 'msg1', 'queued');
    `);

    migrate(db, { migrationsFolder: migrations });

    const rows = (q: string) => sqlite.prepare(q).all();
    expect(rows('SELECT id, restrictions FROM api_keys ORDER BY id')).toEqual([
      { id: 'k1', restrictions: '{}' },
      { id: 'k2', restrictions: '{"mailboxes":["m1"]}' },
    ]);
    expect(
      rows('SELECT name, admin, settings FROM people ORDER BY name'),
    ).toEqual([
      { name: 'Eva', admin: 1, settings: '{}' },
      { name: 'Gideon', admin: 1, settings: '{"language":"Dutch"}' },
    ]);
    expect(
      rows('SELECT kind, subject_type, subject_id, "where", status FROM tasks'),
    ).toEqual([
      {
        kind: 'routine',
        subject_type: 'message',
        subject_id: 'msg1',
        where: 'client',
        status: 'queued',
      },
    ]);
  });
});
