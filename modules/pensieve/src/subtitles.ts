import type { TranscriptSegment } from '@burrow/contracts';

const MAX_CUE = 84;
const MAX_LINE = 42;

// "07:12", or "1:02:03" past the hour.
export function stamp(seconds: number) {
  const s = Math.max(0, Math.floor(seconds));
  const mm = String(Math.floor(s / 60) % 60).padStart(2, '0');
  const ss = String(s % 60).padStart(2, '0');
  return s >= 3600 ? `${Math.floor(s / 3600)}:${mm}:${ss}` : `${mm}:${ss}`;
}

// The transcript as the notes skills read it: one line per segment with
// where it starts, so quotes and chapters can point back into it.
export function timestamped(segments: TranscriptSegment[]) {
  return segments
    .map(
      (s) =>
        `[${stamp(s.start)}] ${s.speaker ? `${s.speaker}: ` : ''}${s.text}`,
    )
    .join('\n');
}

// SubRip subtitles: cues of at most two lines of 42 characters. A long
// segment is cut into cues at word boundaries, its time shared out by length.
export function toSrt(segments: TranscriptSegment[]) {
  const cues: { start: number; end: number; text: string }[] = [];
  for (const segment of segments) {
    const chunks = chunk(segment.text.trim(), MAX_CUE);
    const total = chunks.reduce((n, c) => n + c.length, 0) || 1;
    const span = Math.max(0, segment.end - segment.start);
    let at = segment.start;
    for (const text of chunks) {
      const end = at + (span * text.length) / total;
      cues.push({ start: at, end, text });
      at = end;
    }
  }
  return cues
    .map(
      (c, i) =>
        `${i + 1}\n${srtTime(c.start)} --> ${srtTime(c.end)}\n${lines(c.text).join('\n')}\n`,
    )
    .join('\n');
}

function srtTime(seconds: number) {
  const ms = Math.max(0, Math.round(seconds * 1000));
  const pad = (n: number, w = 2) => String(n).padStart(w, '0');
  return `${pad(Math.floor(ms / 3_600_000))}:${pad(Math.floor(ms / 60_000) % 60)}:${pad(Math.floor(ms / 1000) % 60)},${pad(ms % 1000, 3)}`;
}

function chunk(text: string, max: number) {
  const out: string[] = [];
  let current = '';
  for (const word of text.split(/\s+/).filter(Boolean)) {
    if (current && current.length + 1 + word.length > max) {
      out.push(current);
      current = word;
    } else {
      current = current ? `${current} ${word}` : word;
    }
  }
  if (current) out.push(current);
  return out;
}

// Breaks a cue into two lines at the space nearest the middle.
function lines(text: string) {
  if (text.length <= MAX_LINE) return [text];
  const middle = text.length / 2;
  let best = -1;
  for (let i = 0; i < text.length; i++) {
    if (
      text[i] === ' ' &&
      (best < 0 || Math.abs(i - middle) < Math.abs(best - middle))
    ) {
      best = i;
    }
  }
  return best < 0 ? [text] : [text.slice(0, best), text.slice(best + 1)];
}
