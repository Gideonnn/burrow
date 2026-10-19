import { resolve } from 'node:path';
import { z } from 'zod';

const env = z.object({
  BURROW_PORT: z.coerce.number().int().positive().default(4717),
  BURROW_HOST: z.string().default('127.0.0.1'),
  BURROW_DATA_DIR: z.string().default('.data'),
});

export type Config = {
  port: number;
  host: string;
  dataDir: string;
  dbPath: string;
};

export function loadConfig(source: NodeJS.ProcessEnv = process.env): Config {
  const parsed = env.parse(source);
  const dataDir = resolve(parsed.BURROW_DATA_DIR);
  return {
    port: parsed.BURROW_PORT,
    host: parsed.BURROW_HOST,
    dataDir,
    dbPath: resolve(dataDir, 'burrow.sqlite'),
  };
}
