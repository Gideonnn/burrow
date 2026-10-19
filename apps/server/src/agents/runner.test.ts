import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ClaudeCliRunner, FallbackRunner, parseJsonAnswer } from './runner';

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'burrow-runner-'));
});
afterEach(() => rm(dir, { recursive: true, force: true }));

// A stand-in `claude` that records its arguments and stdin, then prints the
// given JSON envelope.
async function fakeClaude(envelope: object, exitCode = 0) {
  const script = join(dir, 'claude');
  await writeFile(
    script,
    `#!/usr/bin/env node
const fs = require('fs');
let input = '';
process.stdin.on('data', (d) => (input += d));
process.stdin.on('end', () => {
  fs.writeFileSync(${JSON.stringify(join(dir, 'call.json'))}, JSON.stringify({ args: process.argv.slice(2), input }));
  process.stdout.write(${JSON.stringify(JSON.stringify(envelope))});
  process.exit(${exitCode});
});
`,
  );
  await chmod(script, 0o755);
  return script;
}

const request = {
  model: 'haiku',
  system: 'You are Kreacher.',
  prompt: 'mail here',
  schema: { type: 'object' },
};

describe('ClaudeCliRunner', () => {
  it('runs claude headless without tools or MCP and returns the structured output', async () => {
    const runner = new ClaudeCliRunner(
      await fakeClaude({ result: 'ignored', structured_output: { ok: 1 } }),
    );
    expect(await runner.run(request)).toEqual({ ok: 1 });
    const call = JSON.parse(await readFile(join(dir, 'call.json'), 'utf8'));
    expect(call.input).toBe('mail here');
    expect(call.args).toEqual(
      expect.arrayContaining([
        '-p',
        '--model',
        'haiku',
        '--tools',
        '',
        '--strict-mcp-config',
        '--system-prompt',
        'You are Kreacher.',
      ]),
    );
  });

  it('falls back to parsing the text result', async () => {
    const runner = new ClaudeCliRunner(
      await fakeClaude({ result: '```json\n{"ok":2}\n```' }),
    );
    expect(await runner.run(request)).toEqual({ ok: 2 });
  });

  it('reports an error envelope and a failing process', async () => {
    await expect(
      new ClaudeCliRunner(
        await fakeClaude({ is_error: true, result: 'quota' }),
      ).run(request),
    ).rejects.toThrow(/quota/);
    await expect(
      new ClaudeCliRunner(await fakeClaude({}, 3)).run(request),
    ).rejects.toThrow(/exited with 3/);
  });
});

describe('FallbackRunner', () => {
  it('uses the next runner only when the first fails', async () => {
    const used: string[] = [];
    const runner = (name: string, fail: boolean) => ({
      name,
      run: async () => {
        used.push(name);
        if (fail) throw new Error('down');
        return name;
      },
    });
    expect(
      await new FallbackRunner([runner('a', true), runner('b', false)]).run(
        request,
      ),
    ).toBe('b');
    expect(
      await new FallbackRunner([runner('c', false), runner('d', false)]).run(
        request,
      ),
    ).toBe('c');
    expect(used).toEqual(['a', 'b', 'c']);
  });
});

describe('parseJsonAnswer', () => {
  it('accepts plain and fenced JSON', () => {
    expect(parseJsonAnswer('{"a":1}')).toEqual({ a: 1 });
    expect(parseJsonAnswer('```\n{"a":1}\n```')).toEqual({ a: 1 });
  });
});
