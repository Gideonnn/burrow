import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Effort } from '@burrow/contracts';

export type AgentName = 'claude' | 'codex';

export type AgentRequest = {
  model: string;
  effort?: Effort;
  system: string;
  prompt: string;
  // JSON Schema the answer must match.
  schema: object;
  // The agent CLI the bot prefers; the others remain the fallback.
  agent?: AgentName | 'any' | 'local';
  timeoutMs?: number;
  // An embedding request for a local model rather than a chat turn; see
  // claimedTask in the contracts.
  embed?: boolean;
  // Someone is waiting for the answer (a search); it goes before background
  // work.
  urgent?: boolean;
  // false asks the CLI not to think. Haiku 4.5 then planned a search in 6 s
  // instead of 14; Haiku 5.5 thinks anyway and plans in about 4 s.
  thinking?: boolean;
};

// Runs one agent turn and returns its JSON answer. The answer is unvalidated:
// callers parse it with their own zod schema.
export interface AgentRunner {
  readonly name: string;
  run(request: AgentRequest): Promise<unknown>;
}

const TIMEOUT_MS = 120_000;

// Agents get a clean environment: the server's own settings (the secret key,
// OAuth secrets, the OpenAI key for transcription) never reach a process that
// reads untrusted mail. Only what the CLIs need to find their own login.
const PASSED_ENV =
  /^(PATH|HOME|USER|LOGNAME|LANG|LC_[A-Z]+|TMPDIR|TZ|XDG_[A-Z_]+|CLAUDE_[A-Z_]+|CODEX_HOME)$/;

function agentEnv(source: NodeJS.ProcessEnv = process.env) {
  return Object.fromEntries(
    Object.entries(source).filter(([name]) => PASSED_ENV.test(name)),
  );
}

// Claude Code headless on the machine's own login. No tools and no MCP
// servers: a triage turn only reads the prompt and answers, so a crafted mail
// has nothing to call.
export class ClaudeCliRunner implements AgentRunner {
  readonly name = 'claude';

  constructor(private readonly command = 'claude') {}

  async run({
    model,
    effort,
    system,
    prompt,
    schema,
    timeoutMs,
    thinking,
  }: AgentRequest): Promise<unknown> {
    const stdout = await exec(
      this.command,
      [
        '-p',
        '--model',
        model,
        ...(effort ? ['--effort', effort] : []),
        '--output-format',
        'json',
        '--tools',
        '',
        '--strict-mcp-config',
        '--no-session-persistence',
        '--system-prompt',
        system,
        '--json-schema',
        JSON.stringify(schema),
      ],
      prompt,
      {
        timeoutMs,
        extra: thinking === false ? { MAX_THINKING_TOKENS: '0' } : {},
      },
    );
    const envelope = JSON.parse(stdout) as {
      is_error?: boolean;
      result?: string;
      structured_output?: unknown;
    };
    if (envelope.is_error)
      throw new Error(`claude failed: ${envelope.result ?? 'unknown error'}`);
    return envelope.structured_output ?? parseJsonAnswer(envelope.result ?? '');
  }
}

// Codex headless, logged in with the ChatGPT plan. Its sandbox is read-only,
// it starts in an empty folder with a clean environment, and the answer is
// read from --output-last-message. Bots name Claude models, so Codex runs its
// own default model unless BURROW_CODEX_MODEL names another: a ChatGPT login
// refuses model names it does not offer (it refused gpt-6.1-sol).
export class CodexCliRunner implements AgentRunner {
  readonly name = 'codex';

  constructor(
    private readonly command = 'codex',
    private readonly model?: string,
  ) {}

  async run({
    effort,
    system,
    prompt,
    schema,
    timeoutMs,
  }: AgentRequest): Promise<unknown> {
    const dir = await mkdtemp(join(tmpdir(), 'burrow-codex-'));
    try {
      const schemaFile = join(dir, 'schema.json');
      const answerFile = join(dir, 'answer.json');
      await writeFile(schemaFile, JSON.stringify(strictSchema(schema)));
      await exec(
        this.command,
        [
          'exec',
          ...(this.model ? ['--model', this.model] : []),
          ...(effort ? ['-c', `model_reasoning_effort="${effort}"`] : []),
          '--sandbox',
          'read-only',
          '--skip-git-repo-check',
          '--ephemeral',
          '-c',
          'shell_environment_policy.inherit="none"',
          '--output-schema',
          schemaFile,
          '--output-last-message',
          answerFile,
          '-',
        ],
        `${system}\n\n${prompt}`,
        { cwd: dir, timeoutMs },
      );
      return parseJsonAnswer(await readFile(answerFile, 'utf8'));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }
}

// Tries runners in order, the bot's preferred agent first; the next one only
// runs when the previous one failed.
export class FallbackRunner implements AgentRunner {
  readonly name: string;

  constructor(private readonly runners: AgentRunner[]) {
    this.name = runners.map((r) => r.name).join('+');
  }

  async run(request: AgentRequest): Promise<unknown> {
    if (request.agent === 'local') {
      throw new Error('a local bot never runs on a cloud agent');
    }
    let lastError: unknown = new Error(
      'no agent CLI configured (BURROW_AGENTS)',
    );
    const preferred = request.agent ?? 'any';
    const ordered = [
      ...this.runners.filter((r) => r.name === preferred),
      ...this.runners.filter((r) => r.name !== preferred),
    ];
    for (const runner of ordered) {
      try {
        return await runner.run(request);
      } catch (error) {
        lastError = error;
        console.error(`${runner.name} failed: ${(error as Error).message}`);
      }
    }
    throw lastError;
  }
}

// At most `limit` agent runs at once across triage, insights and tasks, so a
// burst of mail does not start twenty CLIs on a small machine. A run someone
// waits for skips the queue and has one place of its own, so a search never
// waits behind reply suggestions for a mail just opened.
export class LimitedRunner implements AgentRunner {
  readonly name: string;
  private active = 0;
  private readonly waiting: { urgent: boolean; go: () => void }[] = [];

  constructor(
    private readonly runner: AgentRunner,
    private readonly limit: number,
  ) {
    this.name = runner.name;
  }

  private room(urgent: boolean) {
    return this.active < this.limit + (urgent ? 1 : 0);
  }

  async run(request: AgentRequest): Promise<unknown> {
    const urgent = Boolean(request.urgent);
    if (!this.room(urgent)) {
      await new Promise<void>((go) => {
        const entry = { urgent, go };
        if (urgent) {
          const firstCalm = this.waiting.findIndex((w) => !w.urgent);
          this.waiting.splice(
            firstCalm < 0 ? this.waiting.length : firstCalm,
            0,
            entry,
          );
        } else {
          this.waiting.push(entry);
        }
      });
    }
    this.active++;
    try {
      return await this.runner.run(request);
    } finally {
      this.active--;
      const next = this.waiting[0];
      if (next && this.room(next.urgent)) {
        this.waiting.shift();
        next.go();
      }
    }
  }
}

// OpenAI's strict structured output refuses oneOf, which zod writes for a
// discriminated union; anyOf means the same there, as the branches exclude
// each other.
function strictSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(strictSchema);
  if (!schema || typeof schema !== 'object') return schema;
  return Object.fromEntries(
    Object.entries(schema).map(([key, value]) => [
      key === 'oneOf' ? 'anyOf' : key,
      strictSchema(value),
    ]),
  );
}

export function parseJsonAnswer(text: string): unknown {
  const trimmed = text
    .trim()
    .replace(/^```(?:json)?\s*([\s\S]*?)\s*```$/, '$1');
  return JSON.parse(trimmed);
}

// Claude prints its JSON envelope even when it exits with an error, and keeps
// stderr empty: an expired login is only readable there.
function envelopeError(stdout: string): string {
  try {
    const envelope = JSON.parse(stdout) as { result?: unknown };
    return typeof envelope.result === 'string' ? envelope.result : '';
  } catch {
    return '';
  }
}

function exec(
  command: string,
  args: string[],
  input: string,
  {
    cwd,
    timeoutMs = TIMEOUT_MS,
    extra = {},
  }: { cwd?: string; timeoutMs?: number; extra?: Record<string, string> } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: Object.assign(agentEnv(), extra),
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error(`${command} timed out after ${timeoutMs / 1000}s`));
    }, timeoutMs);
    child.stdout.on('data', (d: Buffer) => (stdout += d));
    child.stderr.on('data', (d: Buffer) => (stderr += d));
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout);
      else
        reject(
          new Error(
            `${command} exited with ${code}: ${(stderr.trim() || envelopeError(stdout)).slice(0, 500)}`,
          ),
        );
    });
    child.stdin.end(input);
  });
}
