import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { renderNotes } from './notes';
import { stamp, toSrt } from './subtitles';
import { joinParts, OpenAITranscriber } from './transcribe';

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
    ).transcribe(part(), {
      language: 'nl',
      speakers: false,
      timestamps: false,
    });
    expect(text).toEqual({ text: 'Hallo allemaal.', segments: null });
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
          { speaker: 'A', text: ' Zullen we beginnen? ', start: 0.5, end: 2 },
          { speaker: 'B', text: 'Ja.', start: 2.2, end: 2.6 },
        ],
      }),
    );
    const text = await new OpenAITranscriber(
      'sk-test',
      undefined,
      api.fetchFn,
    ).transcribe(part(), { language: 'nl', speakers: true, timestamps: true });
    expect(text).toEqual({
      text: 'A: Zullen we beginnen?\nB: Ja.',
      segments: [
        { start: 0.5, end: 2, speaker: 'A', text: 'Zullen we beginnen?' },
        { start: 2.2, end: 2.6, speaker: 'B', text: 'Ja.' },
      ],
    });
    expect(api.calls[0]?.form.get('model')).toBe('gpt-4o-transcribe-diarize');
    expect(api.calls[0]?.form.get('chunking_strategy')).toBe('auto');
  });

  it('gives timestamps without speakers when only subtitles are wanted', async () => {
    const api = openai(
      JSON.stringify({
        segments: [
          { speaker: 'A', text: 'Welkom.', start: 0, end: 1 },
          { speaker: 'B', text: 'Dank je.', start: 1.2, end: 2 },
        ],
      }),
    );
    const out = await new OpenAITranscriber(
      'sk-test',
      undefined,
      api.fetchFn,
    ).transcribe(part(), { language: 'nl', speakers: false, timestamps: true });
    expect(out.text).toBe('Welkom. Dank je.');
    expect(out.segments?.map((s) => s.speaker)).toEqual([null, null]);
    expect(api.calls[0]?.form.get('response_format')).toBe('diarized_json');
  });

  it('reports what OpenAI said when it refuses', async () => {
    const api = openai('{"error":"quota"}', 429);
    await expect(
      new OpenAITranscriber('sk-test', undefined, api.fetchFn).transcribe(
        part(),
        {
          language: 'nl',
          speakers: false,
          timestamps: false,
        },
      ),
    ).rejects.toThrow('OpenAI answered 429');
  });
});

describe('joining parts', () => {
  it('moves the segments of later parts to where those parts start', () => {
    const joined = joinParts([
      {
        start: 0,
        transcription: {
          text: 'A: Een.',
          segments: [{ start: 1, end: 2, speaker: 'A', text: 'Een.' }],
        },
      },
      {
        start: 1200.064,
        transcription: {
          text: 'B: Twee.',
          segments: [{ start: 3, end: 4.5, speaker: 'B', text: 'Twee.' }],
        },
      },
    ]);
    expect(joined).toEqual({
      text: 'A: Een.\nB: Twee.',
      segments: [
        { start: 1, end: 2, speaker: 'A', text: 'Een.' },
        { start: 1203.064, end: 1204.564, speaker: 'B', text: 'Twee.' },
      ],
    });
  });

  it('keeps no segments when a part came without them', () => {
    const joined = joinParts([
      { start: 0, transcription: { text: 'Een.', segments: null } },
    ]);
    expect(joined.segments).toBeNull();
  });
});

describe('subtitles', () => {
  it('writes SubRip cues with times from the segments', () => {
    expect(
      toSrt([
        {
          start: 1.5,
          end: 3.25,
          speaker: 'A',
          text: 'Welkom bij de bakkerij.',
        },
        { start: 3661, end: 3662, speaker: 'B', text: 'Dank je.' },
      ]),
    ).toBe(
      '1\n00:00:01,500 --> 00:00:03,250\nWelkom bij de bakkerij.\n\n2\n01:01:01,000 --> 01:01:02,000\nDank je.\n',
    );
  });

  it('cuts a long segment into cues of two short lines, sharing its time', () => {
    const text =
      'Brood is geduld dat je kunt eten, zei mijn vader altijd, en hij had gelijk want de vaste klanten proeven het verschil meteen.';
    const srt = toSrt([{ start: 0, end: 10, speaker: null, text }]);
    const cues = srt.trim().split('\n\n');
    expect(cues).toHaveLength(2);
    for (const cue of cues) {
      const lines = cue.split('\n').slice(2);
      expect(lines.length).toBeLessThanOrEqual(2);
      for (const line of lines) expect(line.length).toBeLessThanOrEqual(44);
    }
    expect(cues[1]).toContain('--> 00:00:10,000');
  });

  it('stamps minutes, and hours past the hour', () => {
    expect(stamp(432)).toBe('07:12');
    expect(stamp(3723)).toBe('1:02:03');
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

  it('gives an interview its core, quotes with their moment and chapters', () => {
    const md = renderNotes(
      {
        type: 'interview',
        title: null,
        summary: 'Joris bakt al twintig jaar.',
        quotes: [
          { text: 'Brood is geduld dat je kunt eten.', speaker: 'B', at: 432 },
        ],
        chapters: [{ title: 'Begin in de garage', at: 125 }],
      },
      'Dutch',
    );
    expect(md).toBe(
      '## Kern\n\nJoris bakt al twintig jaar.\n\n## Citaten\n\n- "Brood is geduld dat je kunt eten." (B, 07:12)\n\n## Hoofdstukken\n\n- 02:05 Begin in de garage\n',
    );
  });

  it('numbers the steps of a screen recording', () => {
    const md = renderNotes(
      {
        type: 'steps',
        title: null,
        summary: 'Een rapportage maken.',
        steps: [
          { text: 'Open Rapportages.', at: 42 },
          { text: 'Kies Nieuw.', at: null },
        ],
      },
      'English',
    );
    expect(md).toContain(
      '## Steps\n\n1. Open Rapportages. (00:42)\n2. Kies Nieuw.\n',
    );
  });
});
