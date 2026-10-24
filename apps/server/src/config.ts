import { resolve } from 'node:path';
import type { OAuthAppConfig } from '@burrow/hedwig/server';
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
  BURROW_NOTES_BOT: z.string().default('kreacher'),
  // An address for the public privacy and terms pages.
  BURROW_CONTACT_EMAIL: z.string().optional(),
  // Language for reasons and other text the bots write, e.g. Dutch.
  BURROW_LANGUAGE: z.string().default('English'),
  // Agent CLIs to try in order for headless runs.
  BURROW_AGENTS: z.string().default('claude,codex'),
  BURROW_CLAUDE_COMMAND: z.string().default('claude'),
  BURROW_CODEX_COMMAND: z.string().default('codex'),
  // A Codex model; empty uses Sol 6.1.
  BURROW_CODEX_MODEL: z.string().optional(),
  // Server tasks at once, and agent CLI runs at once across everything.
  BURROW_WORKERS: z.coerce.number().int().min(1).max(8).default(2),
  BURROW_AGENT_RUNS: z.coerce.number().int().min(1).max(8).default(2),
  // Development without Cloudflare Access: the person the device login
  // assumes for requests from this machine. Ignored when Access is set.
  BURROW_DEV_LOGIN: z.string().optional(),
  // Pensieve: transcription through OpenAI, and the ffmpeg binary.
  OPENAI_API_KEY: z.string().optional(),
  BURROW_TRANSCRIBE_MODEL: z.string().default('gpt-4o-transcribe'),
  BURROW_FFMPEG: z.string().default('ffmpeg'),
  BURROW_FFPROBE: z.string().default('ffprobe'),
  // Lumos: `fixture` serves the test catalogue, for development only.
  LUMOS_CATALOGUE: z.enum(['fixture']).optional(),
  // The real catalogue (Seerr); its presence alone rules out the fixtures.
  LUMOS_SEERR_URL: z.string().optional(),
});

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
  notesBot: string;
  contact: string | undefined;
  language: string;
  agents: { name: 'claude' | 'codex'; command: string }[];
  codexModel: string | undefined;
  workers: number;
  agentRuns: number;
  devLoginAs: string | undefined;
  openaiKey: string | undefined;
  transcribeModel: string;
  ffmpeg: string;
  ffprobe: string;
  lumosCatalogue: 'fixture' | undefined;
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
    notesBot: parsed.BURROW_NOTES_BOT,
    contact: parsed.BURROW_CONTACT_EMAIL || undefined,
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
    codexModel: parsed.BURROW_CODEX_MODEL || undefined,
    workers: parsed.BURROW_WORKERS,
    agentRuns: parsed.BURROW_AGENT_RUNS,
    devLoginAs: team ? undefined : parsed.BURROW_DEV_LOGIN,
    openaiKey: parsed.OPENAI_API_KEY || undefined,
    transcribeModel: parsed.BURROW_TRANSCRIBE_MODEL,
    ffmpeg: parsed.BURROW_FFMPEG,
    ffprobe: parsed.BURROW_FFPROBE,
    lumosCatalogue: lumosCatalogue(parsed, Boolean(team)),
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

// Fixture titles must never pass for the real catalogue: they are refused
// next to a configured Seerr and on a deployed server (Access or a public
// address), so they only ever run on a developer's own machine.
function lumosCatalogue(
  parsed: z.infer<typeof env>,
  behindAccess: boolean,
): 'fixture' | undefined {
  if (parsed.LUMOS_CATALOGUE !== 'fixture') return undefined;
  const host = parsed.BURROW_PUBLIC_URL
    ? new URL(parsed.BURROW_PUBLIC_URL).hostname
    : '127.0.0.1';
  const local = ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(host);
  if (parsed.LUMOS_SEERR_URL || behindAccess || !local) {
    throw new Error(
      'LUMOS_CATALOGUE=fixture is for local development only: unset it, or LUMOS_SEERR_URL, Cloudflare Access and a public BURROW_PUBLIC_URL',
    );
  }
  return 'fixture';
}
