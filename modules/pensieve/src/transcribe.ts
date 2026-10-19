import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';

export type TranscribeOptions = {
  // ISO 639-1, e.g. "nl".
  language: string;
  // Label who speaks ("A:", "B:"), with the diarizing model.
  speakers: boolean;
};

// Turns one audio part into text. The pipeline splits long recordings first,
// so an engine only ever sees parts within its caps.
export interface Transcriber {
  readonly name: string;
  // Longest part the engine accepts, in seconds.
  readonly maxSeconds: number;
  transcribe(file: string, options: TranscribeOptions): Promise<string>;
}

const API = 'https://api.openai.com/v1/audio/transcriptions';

// OpenAI's transcription API. gpt-4o-transcribe rejects audio longer than
// 1400 s and uploads over 25 MB; parts of 20 minutes at 32 kbit/s are about
// 5 MB, well inside both.
export class OpenAITranscriber implements Transcriber {
  readonly name = 'openai';
  readonly maxSeconds = 1200;

  constructor(
    private readonly apiKey: string,
    private readonly model = 'gpt-4o-transcribe',
    private readonly fetchFn: typeof fetch = fetch,
  ) {}

  async transcribe(file: string, { language, speakers }: TranscribeOptions) {
    const model = speakers ? 'gpt-4o-transcribe-diarize' : this.model;
    const form = new FormData();
    form.set('model', model);
    form.set('language', language);
    form.set('response_format', speakers ? 'diarized_json' : 'text');
    if (speakers) form.set('chunking_strategy', 'auto');
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
    if (!speakers) return body.trim();
    const { segments } = JSON.parse(body) as {
      segments?: { speaker?: string; text?: string }[];
    };
    return (segments ?? [])
      .filter((s) => s.text)
      .map((s) => `${s.speaker ?? '?'}: ${s.text!.trim()}`)
      .join('\n');
  }
}
