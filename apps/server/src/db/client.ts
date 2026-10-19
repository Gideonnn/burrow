import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import type { Db } from '@burrow/platform';
import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';

const migrationsFolder = resolve(import.meta.dirname, 'migrations');

// `:memory:` gives each test its own empty database.
export function openDb(path: string): Db {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const sqlite = new Database(path);
  sqlite.pragma('journal_mode = WAL');
  sqlite.pragma('foreign_keys = ON');
  const db = drizzle(sqlite);
  migrate(db, { migrationsFolder });
  return db;
}
