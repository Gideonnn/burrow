import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { renderNotes } from './notes';
import { OpenAITranscriber } from './transcribe';

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true });
});

function part() {
  const dir = mkdtempSync(join(tmpdir(), 'pensieve-part-'));
  dirs.push(dir);
  const file = join(dir, 'part-000.m4a');
  writeFileSync(file, 'audio');
  return file;
}

function openai(answer: string, status = 200) {
  const calls: { url: string; form: FormData; auth: string }[] = [];
  const fetchFn = (async (url: string, init: RequestInit) => {
    calls.push({
      url,
      form: init.body as FormData,
      auth: new Headers(init.headers).get('authorization') ?? '',
    });
    return new Response(answer, { status });
  }) as unknown as typeof fetch;
  return { calls, fetchFn };
}

describe('the OpenAI transcriber', () => {
  it('sends the part with the language and returns the text', async () => {
    const api = openai('Hallo allemaal.\n');
    const text = await new OpenAITranscriber(
      'sk-test',
      undefined,
      api.fetchFn,
    ).transcribe(part(), { language: 'nl', speakers: false });
    expect(text).toBe('Hallo allemaal.');
    const [call] = api.calls;
    expect(call?.auth).toBe('Bearer sk-test');
    expect(call?.form.get('model')).toBe('gpt-4o-transcribe');
    expect(call?.form.get('language')).toBe('nl');
    expect(call?.form.get('response_format')).toBe('text');
  });

  it('labels speakers with the diarizing model', async () => {
    const api = openai(
      JSON.stringify({
        segments: [
          { speaker: 'A', text: ' Zullen we beginnen? ' },
          { speaker: 'B', text: 'Ja.' },
        ],
      }),
    );
    const text = await new OpenAITranscriber(
      'sk-test',
      undefined,
      api.fetchFn,
    ).transcribe(part(), { language: 'nl', speakers: true });
    expect(text).toBe('A: Zullen we beginnen?\nB: Ja.');
    expect(api.calls[0]?.form.get('model')).toBe('gpt-4o-transcribe-diarize');
  });

  it('reports what OpenAI said when it refuses', async () => {
    const api = openai('{"error":"quota"}', 429);
    await expect(
      new OpenAITranscriber('sk-test', undefined, api.fetchFn).transcribe(
        part(),
        {
          language: 'nl',
          speakers: false,
        },
      ),
    ).rejects.toThrow('OpenAI answered 429');
  });
});

describe('rendering notes', () => {
  it('leaves out empty sections and writes Dutch headings for Dutch notes', () => {
    const md = renderNotes(
      {
        title: null,
        summary: 'Kort overleg.',
        decisions: [],
        actions: [{ text: 'Offerte sturen', owner: null, due: 'vrijdag' }],
        openQuestions: [],
      },
      'Dutch',
    );
    expect(md).toBe(
      '## Samenvatting\n\nKort overleg.\n\n## Actiepunten\n\n- [ ] Offerte sturen · vrijdag\n',
    );
  });
});
