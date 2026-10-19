import { resolve } from 'node:path';
import { z } from 'zod';

const env = z.object({
  BURROW_PORT: z.coerce.number().int().positive().default(4717),
  BURROW_HOST: z.string().default('127.0.0.1'),
  BURROW_DATA_DIR: z.string().default('.data'),
  // The address browsers use to reach the server, for OAuth redirects. On
  // Dobby this is the Tailscale HTTPS name.
  BURROW_PUBLIC_URL: z.url().optional(),
  BURROW_SECRET_KEY: z.string().optional(),
  GOOGLE_CLIENT_ID: z.string().optional(),
  GOOGLE_CLIENT_SECRET: z.string().optional(),
  MICROSOFT_CLIENT_ID: z.string().optional(),
  MICROSOFT_CLIENT_SECRET: z.string().optional(),
});

export type OAuthAppConfig = { clientId: string; clientSecret?: string };

export type Config = {
  port: number;
  host: string;
  dataDir: string;
  dbPath: string;
  publicUrl: string;
  secretKey: string | undefined;
  google: OAuthAppConfig | undefined;
  microsoft: OAuthAppConfig | undefined;
};

export function loadConfig(source: NodeJS.ProcessEnv = process.env): Config {
  const parsed = env.parse(source);
  const dataDir = resolve(parsed.BURROW_DATA_DIR);
  return {
    port: parsed.BURROW_PORT,
    host: parsed.BURROW_HOST,
    dataDir,
    dbPath: resolve(dataDir, 'burrow.sqlite'),
    publicUrl: (
      parsed.BURROW_PUBLIC_URL ?? `http://127.0.0.1:${parsed.BURROW_PORT}`
    ).replace(/\/$/, ''),
    secretKey: parsed.BURROW_SECRET_KEY,
    google: parsed.GOOGLE_CLIENT_ID
      ? {
          clientId: parsed.GOOGLE_CLIENT_ID,
          clientSecret: parsed.GOOGLE_CLIENT_SECRET,
        }
      : undefined,
    microsoft: parsed.MICROSOFT_CLIENT_ID
      ? {
          clientId: parsed.MICROSOFT_CLIENT_ID,
          clientSecret: parsed.MICROSOFT_CLIENT_SECRET,
        }
      : undefined,
  };
}
