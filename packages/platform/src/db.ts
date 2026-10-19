import type Database from 'better-sqlite3';
import type { BetterSQLite3Database } from 'drizzle-orm/better-sqlite3';

// The server opens the database with every module's tables; the platform and
// modules only use the query builder, so they need no schema in the type.
export type Db = BetterSQLite3Database<Record<string, unknown>> & {
  $client: Database.Database;
};
