import { z } from 'zod';

const env = z.object({
  BURROW_PORT: z.coerce.number().int().positive().default(4717),
  BURROW_HOST: z.string().default('127.0.0.1'),
});

export type Config = {
  port: number;
  host: string;
};

export function loadConfig(source: NodeJS.ProcessEnv = process.env): Config {
  const parsed = env.parse(source);
  return { port: parsed.BURROW_PORT, host: parsed.BURROW_HOST };
}
