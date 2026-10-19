import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export type AgentRequest = {
  model: string;
  system: string;
  prompt: string;
  // JSON Schema the answer must match.
  schema: object;
};

// Runs one agent turn and returns its JSON answer. The answer is unvalidated:
// callers parse it with their own zod schema.
export interface AgentRunner {
  readonly name: string;
  run(request: AgentRequest): Promise<unknown>;
}

const TIMEOUT_MS = 120_000;

// Claude Code headless on the machine's own login. No tools and no MCP
// servers: a triage turn only reads the prompt and answers, so a crafted mail
// has nothing to call.
export class ClaudeCliRunner implements AgentRunner {
  readonly name = 'claude';

  constructor(private readonly command = 'claude') {}

  async run({ model, system, prompt, schema }: AgentRequest): Promise<unknown> {
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

// Codex headless as a fallback. Its sandbox is read-only and the answer is
// read from --output-last-message.
export class CodexCliRunner implements AgentRunner {
  readonly name = 'codex';

  constructor(private readonly command = 'codex') {}

  async run({ model, system, prompt, schema }: AgentRequest): Promise<unknown> {
    const dir = await mkdtemp(join(tmpdir(), 'burrow-codex-'));
    try {
      const schemaFile = join(dir, 'schema.json');
      const answerFile = join(dir, 'answer.json');
      await writeFile(schemaFile, JSON.stringify(schema));
      await exec(
        this.command,
        [
          'exec',
          ...(model ? ['--model', model] : []),
          '--sandbox',
          'read-only',
          '--skip-git-repo-check',
          '--output-schema',
          schemaFile,
          '--output-last-message',
          answerFile,
          '-',
        ],
        `${system}\n\n${prompt}`,
        dir,
      );
      return parseJsonAnswer(await readFile(answerFile, 'utf8'));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }
}

// Tries runners in order; the next one only runs when the previous one failed.
export class FallbackRunner implements AgentRunner {
  readonly name: string;

  constructor(private readonly runners: AgentRunner[]) {
    this.name = runners.map((r) => r.name).join('+');
  }

  async run(request: AgentRequest): Promise<unknown> {
    let lastError: unknown = new Error(
      'no agent CLI configured (BURROW_AGENTS)',
    );
    for (const runner of this.runners) {
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
  cwd?: string,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error(`${command} timed out after ${TIMEOUT_MS / 1000}s`));
    }, TIMEOUT_MS);
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
