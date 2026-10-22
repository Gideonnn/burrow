import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import type { TranscriptSegment } from '@burrow/contracts';

export type TranscribeOptions = {
  // ISO 639-1, e.g. "nl".
  language: string;
  // Label who speaks ("A", "B"), with the diarizing model.
  speakers: boolean;
  // Segments with start and end, for subtitles and the timeline.
  timestamps: boolean;
};

export type Transcription = {
  text: string;
  // Seconds from the start of the part; null when the engine gave none.
  segments: TranscriptSegment[] | null;
};

// Turns one audio part into text. The pipeline splits long recordings first,
// so an engine only ever sees parts within its caps.
export interface Transcriber {
  readonly name: string;
  // Longest part the engine accepts, in seconds.
  readonly maxSeconds: number;
  transcribe(file: string, options: TranscribeOptions): Promise<Transcription>;
}

const API = 'https://api.openai.com/v1/audio/transcriptions';
const DIARIZE = 'gpt-4o-transcribe-diarize';

// OpenAI's transcription API. gpt-4o-transcribe rejects audio longer than
// 1400 s and uploads over 25 MB; parts of 20 minutes at 32 kbit/s are about
// 5 MB, well inside both. Of the current models only the diarizing one
// returns timestamps (gpt-4o-transcribe and gpt-transcribe give text only,
// whisper-1 is older), so it serves every request for speakers or segments.
export class OpenAITranscriber implements Transcriber {
  readonly name = 'openai';
  readonly maxSeconds = 1200;

  constructor(
    private readonly apiKey: string,
    private readonly model = 'gpt-4o-transcribe',
    private readonly fetchFn: typeof fetch = fetch,
  ) {}

  async transcribe(
    file: string,
    { language, speakers, timestamps }: TranscribeOptions,
  ): Promise<Transcription> {
    const diarize = speakers || timestamps;
    const form = new FormData();
    form.set('model', diarize ? DIARIZE : this.model);
    form.set('language', language);
    form.set('response_format', diarize ? 'diarized_json' : 'text');
    // Required by the diarizing model for anything over 30 seconds.
    if (diarize) form.set('chunking_strategy', 'auto');
    form.set(
      'file',
      new Blob([await readFile(file)], { type: 'audio/mp4' }),
      basename(file),
    );
    const res = await this.fetchFn(API, {
      method: 'POST',
      headers: { authorization: `Bearer ${this.apiKey}` },
      body: form,
      signal: AbortSignal.timeout(15 * 60_000),
    });
    const body = await res.text();
    if (!res.ok) {
      throw new Error(`OpenAI answered ${res.status}: ${body.slice(0, 300)}`);
    }
    if (!diarize) return { text: body.trim(), segments: null };
    const parsed = JSON.parse(body) as {
      segments?: {
        speaker?: string;
        text?: string;
        start?: number;
        end?: number;
      }[];
    };
    const segments: TranscriptSegment[] = (parsed.segments ?? [])
      .filter((s) => s.text?.trim())
      .map((s) => ({
        start: s.start ?? 0,
        end: s.end ?? s.start ?? 0,
        speaker: speakers ? (s.speaker ?? '?') : null,
        text: s.text!.trim(),
      }));
    return { text: plainText(segments), segments };
  }
}

// "A: Zullen we beginnen?" per segment, or the sentences run together
// without speakers.
export function plainText(segments: TranscriptSegment[]) {
  return segments.some((s) => s.speaker)
    ? segments.map((s) => `${s.speaker ?? '?'}: ${s.text}`).join('\n')
    : segments.map((s) => s.text).join(' ');
}

// Joins transcribed parts into one, moving each part's segments to where the
// part starts in the recording.
export function joinParts(
  parts: { start: number; transcription: Transcription }[],
): Transcription {
  const text = parts
    .map((p) => p.transcription.text.trim())
    .filter(Boolean)
    .join('\n');
  if (parts.some((p) => !p.transcription.segments)) {
    return { text, segments: null };
  }
  const round = (n: number) => Math.round(n * 1000) / 1000;
  const segments = parts.flatMap(({ start, transcription }) =>
    transcription.segments!.map((s) => ({
      ...s,
      start: round(s.start + start),
      end: round(s.end + start),
    })),
  );
  return { text, segments };
}
