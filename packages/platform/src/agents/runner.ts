import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export type AgentName = 'claude' | 'codex';

export type AgentRequest = {
  model: string;
  system: string;
  prompt: string;
  // JSON Schema the answer must match.
  schema: object;
  // The agent CLI the bot prefers; the others remain the fallback.
  agent?: AgentName | 'any';
  timeoutMs?: number;
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

export function agentEnv(source: NodeJS.ProcessEnv = process.env) {
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
    system,
    prompt,
    schema,
    timeoutMs,
  }: AgentRequest): Promise<unknown> {
    const stdout = await exec(
      this.command,
      [
        '-p',
        '--model',
        model,
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
      { timeoutMs },
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
// read from --output-last-message. Bots name Claude models, so Codex uses its
// own default unless BURROW_CODEX_MODEL names one.
export class CodexCliRunner implements AgentRunner {
  readonly name = 'codex';

  constructor(
    private readonly command = 'codex',
    private readonly model?: string,
  ) {}

  async run({
    system,
    prompt,
    schema,
    timeoutMs,
  }: AgentRequest): Promise<unknown> {
    const dir = await mkdtemp(join(tmpdir(), 'burrow-codex-'));
    try {
      const schemaFile = join(dir, 'schema.json');
      const answerFile = join(dir, 'answer.json');
      await writeFile(schemaFile, JSON.stringify(schema));
      await exec(
        this.command,
        [
          'exec',
          ...(this.model ? ['--model', this.model] : []),
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
// burst of mail does not start twenty CLIs on a small machine.
export class LimitedRunner implements AgentRunner {
  readonly name: string;
  private active = 0;
  private readonly waiting: (() => void)[] = [];

  constructor(
    private readonly runner: AgentRunner,
    private readonly limit: number,
  ) {
    this.name = runner.name;
  }

  async run(request: AgentRequest): Promise<unknown> {
    if (this.active >= this.limit) {
      await new Promise<void>((go) => this.waiting.push(go));
    }
    this.active++;
    try {
      return await this.runner.run(request);
    } finally {
      this.active--;
      this.waiting.shift()?.();
    }
  }
}

export function parseJsonAnswer(text: string): unknown {
  const trimmed = text
    .trim()
    .replace(/^```(?:json)?\s*([\s\S]*?)\s*```$/, '$1');
  return JSON.parse(trimmed);
}

function exec(
  command: string,
  args: string[],
  input: string,
  { cwd, timeoutMs = TIMEOUT_MS }: { cwd?: string; timeoutMs?: number } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: agentEnv(),
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
          new Error(`${command} exited with ${code}: ${stderr.slice(0, 500)}`),
        );
    });
    child.stdin.end(input);
  });
}
