import { resolve } from 'node:path';
import { z } from 'zod';

const env = z.object({
  BURROW_PORT: z.coerce.number().int().positive().default(4717),
  BURROW_HOST: z.string().default('127.0.0.1'),
  BURROW_DATA_DIR: z.string().default('.data'),
  // The address browsers use to reach the server, for OAuth redirects. On
  // Dobby this is the public hostname of the Cloudflare Tunnel.
  BURROW_PUBLIC_URL: z.url().optional(),
  BURROW_SECRET_KEY: z.string().optional(),
  GOOGLE_CLIENT_ID: z.string().optional(),
  GOOGLE_CLIENT_SECRET: z.string().optional(),
  MICROSOFT_CLIENT_ID: z.string().optional(),
  MICROSOFT_CLIENT_SECRET: z.string().optional(),
  // With both set, a second port serves the Cloudflare Tunnel and admits only
  // people logged in through Access. TEAM is e.g. household.cloudflareaccess.com.
  CLOUDFLARE_ACCESS_TEAM: z.string().optional(),
  CLOUDFLARE_ACCESS_AUD: z.string().optional(),
  BURROW_TUNNEL_PORT: z.coerce.number().int().positive().default(4718),
  // Colon-separated; later directories override earlier ones by name.
  BURROW_BOTS_DIRS: z.string().optional(),
  BURROW_SKILLS_DIRS: z.string().optional(),
  BURROW_TRIAGE_BOT: z.string().default('kreacher'),
  // Language for reasons and other text the bots write, e.g. Dutch.
  BURROW_LANGUAGE: z.string().default('English'),
  // Agent CLIs to try in order for headless runs.
  BURROW_AGENTS: z.string().default('claude,codex'),
  BURROW_CLAUDE_COMMAND: z.string().default('claude'),
  BURROW_CODEX_COMMAND: z.string().default('codex'),
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
  cloudflareAccess:
    | { team: string; audience: string; port: number }
    | undefined;
  botsDirs: string[];
  skillsDirs: string[];
  triageBot: string;
  language: string;
  agents: { name: 'claude' | 'codex'; command: string }[];
};

export function loadConfig(source: NodeJS.ProcessEnv = process.env): Config {
  const parsed = env.parse(source);
  const dataDir = resolve(parsed.BURROW_DATA_DIR);
  const team = parsed.CLOUDFLARE_ACCESS_TEAM?.replace(
    /^https:\/\//,
    '',
  ).replace(/\/$/, '');
  if (!team !== !parsed.CLOUDFLARE_ACCESS_AUD) {
    throw new Error(
      'set both CLOUDFLARE_ACCESS_TEAM and CLOUDFLARE_ACCESS_AUD, or neither',
    );
  }
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
    botsDirs: dirs(parsed.BURROW_BOTS_DIRS, 'bots', dataDir),
    skillsDirs: dirs(parsed.BURROW_SKILLS_DIRS, 'skills', dataDir),
    triageBot: parsed.BURROW_TRIAGE_BOT,
    language: parsed.BURROW_LANGUAGE,
    agents: parsed.BURROW_AGENTS.split(',')
      .map((a) => a.trim())
      .filter((a): a is 'claude' | 'codex' => a === 'claude' || a === 'codex')
      .map((name) => ({
        name,
        command:
          name === 'claude'
            ? parsed.BURROW_CLAUDE_COMMAND
            : parsed.BURROW_CODEX_COMMAND,
      })),
    microsoft: parsed.MICROSOFT_CLIENT_ID
      ? {
          clientId: parsed.MICROSOFT_CLIENT_ID,
          clientSecret: parsed.MICROSOFT_CLIENT_SECRET,
        }
      : undefined,
    cloudflareAccess:
      team && parsed.CLOUDFLARE_ACCESS_AUD
        ? {
            team,
            audience: parsed.CLOUDFLARE_ACCESS_AUD,
            port: parsed.BURROW_TUNNEL_PORT,
          }
        : undefined,
  };
}

// The repository's own bots/ and skills/ (three levels up from src/ or dist/),
// then the personal ones in the data directory.
const repoRoot = resolve(import.meta.dirname, '../../..');

function dirs(
  value: string | undefined,
  name: string,
  dataDir: string,
): string[] {
  if (value)
    return value
      .split(':')
      .filter(Boolean)
      .map((d) => resolve(d));
  return [resolve(repoRoot, name), resolve(dataDir, name)];
}
