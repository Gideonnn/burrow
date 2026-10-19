import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { FfmpegAudio } from './audio';

const hasFfmpeg = (() => {
  try {
    execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true });
});

// Ten seconds of a tone as the recorder writes it: 16 kHz mono 16-bit WAV.
function wav() {
  const dir = mkdtempSync(join(tmpdir(), 'pensieve-audio-'));
  dirs.push(dir);
  const file = join(dir, 'original');
  execFileSync('ffmpeg', [
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:duration=10',
    '-ac',
    '1',
    '-ar',
    '16000',
    '-c:a',
    'pcm_s16le',
    '-f',
    'wav',
    file,
  ]);
  return { dir, file };
}

describe.skipIf(!hasFfmpeg)('ffmpeg', () => {
  it('compresses a WAV to a fraction of its size and reports the duration', async () => {
    const { dir, file } = wav();
    const out = join(dir, 'audio.m4a');
    const { seconds } = await new FfmpegAudio().compress(file, out);
    expect(seconds).toBeCloseTo(10, 0);
    expect(statSync(out).size).toBeLessThan(statSync(file).size / 5);
  });

  it('drops the sliver a split at an exact multiple leaves behind', async () => {
    const { dir, file } = wav();
    const audio = new FfmpegAudio();
    const stored = join(dir, 'audio.m4a');
    await audio.compress(file, stored);
    const parts = await audio.split(stored, dir, 5);
    expect(parts).toHaveLength(2);
  });

  it('splits stored audio into parts the transcription API accepts', async () => {
    const { dir, file } = wav();
    const audio = new FfmpegAudio();
    const stored = join(dir, 'audio.m4a');
    await audio.compress(file, stored);
    const parts = await audio.split(stored, dir, 4);
    expect(parts.map((p) => p.slice(dir.length + 1))).toEqual([
      'part-000.m4a',
      'part-001.m4a',
      'part-002.m4a',
    ]);
    const total = (
      await Promise.all(parts.map((p) => audio.duration(p)))
    ).reduce((a, b) => a + b, 0);
    expect(total).toBeCloseTo(10, 0);
  });
});
