import { execFile } from 'node:child_process';
import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);

// What Pensieve needs from an audio tool; ffmpeg on the server, a fake in
// tests.
export interface Audio {
  // Any input to the stored format; returns the duration in seconds.
  compress(input: string, output: string): Promise<{ seconds: number }>;
  // Cuts a stored file into parts of at most `seconds`, for the
  // transcription API's caps; returns the parts in order with where each
  // starts in the whole recording.
  split(input: string, dir: string, seconds: number): Promise<AudioPart[]>;
}

export type AudioPart = { file: string; start: number };

// AAC, mono, 16 kHz at 32 kbit/s: about 14 MB an hour instead of 115 MB for
// the WAV, plenty for speech, and every Apple device plays it.
export const STORED_EXTENSION = 'm4a';
const ENCODE = [
  '-vn',
  '-ac',
  '1',
  '-ar',
  '16000',
  '-c:a',
  'aac',
  '-b:a',
  '32k',
];
const TIMEOUT_MS = 30 * 60_000;
// About half a second at 32 kbit/s.
const MIN_PART_BYTES = 2_048;

export class FfmpegAudio implements Audio {
  constructor(
    private readonly ffmpeg = 'ffmpeg',
    private readonly ffprobe = 'ffprobe',
  ) {}

  async compress(input: string, output: string) {
    await run(
      this.ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        input,
        ...ENCODE,
        '-movflags',
        '+faststart',
        output,
      ],
      { timeout: TIMEOUT_MS },
    );
    return { seconds: await this.duration(output) };
  }

  async split(input: string, dir: string, seconds: number) {
    await run(
      this.ffmpeg,
      [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        input,
        '-f',
        'segment',
        '-segment_time',
        String(seconds),
        '-segment_format',
        'mp4',
        '-reset_timestamps',
        '1',
        '-c',
        'copy',
        join(dir, `part-%03d.${STORED_EXTENSION}`),
      ],
      { timeout: TIMEOUT_MS },
    );
    const parts = (await readdir(dir))
      .filter((f) => f.startsWith('part-'))
      .sort()
      .map((f) => join(dir, f));
    // Cutting at exact multiples leaves a last part of a few milliseconds,
    // which the transcription API refuses as too short. A copy cuts on
    // packet boundaries, so starts are measured rather than multiplied.
    const kept: AudioPart[] = [];
    let start = 0;
    for (const [i, file] of parts.entries()) {
      if ((await stat(file)).size >= MIN_PART_BYTES) kept.push({ file, start });
      if (i < parts.length - 1) start += await this.duration(file);
    }
    return kept;
  }

  async duration(file: string): Promise<number> {
    const { stdout } = await run(this.ffprobe, [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      file,
    ]);
    const seconds = Number.parseFloat(stdout.trim());
    if (!Number.isFinite(seconds))
      throw new Error('could not read the duration');
    return seconds;
  }
}
