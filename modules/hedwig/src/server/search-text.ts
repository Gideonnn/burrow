import type { SearchHit } from '@burrow/contracts';

// Lower case without accents, one UTF-16 unit for one, so positions in the
// folded text are positions in the original ("café" and "cafe" both fold to
// "cafe" at the same offsets).
export function fold(text: string): string {
  let out = '';
  for (const ch of text) {
    const plain = ch.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
    out +=
      plain.length === ch.length
        ? plain
        : ch.toLowerCase().padEnd(ch.length).slice(0, ch.length);
  }
  return out;
}

// The words FTS5's unicode61 tokenizer would make of a text, folded.
export const tokens = (text: string): string[] =>
  fold(text).match(/[\p{L}\p{N}]+/gu) ?? [];

export type ParsedQuery = {
  words: string[];
  phrases: string[];
  excluded: string[];
  mentions: string[];
};

// What someone typed: words, "a phrase", -leave-out and @someone.
export function parseQuery(q: string): ParsedQuery {
  const parsed: ParsedQuery = {
    words: [],
    phrases: [],
    excluded: [],
    mentions: [],
  };
  for (const m of q.matchAll(/(-?)"([^"]*)"?|(\S+)/g)) {
    if (m[2] !== undefined) {
      const phrase = m[2].trim();
      if (!phrase) continue;
      (m[1] ? parsed.excluded : parsed.phrases).push(phrase);
      continue;
    }
    const word = m[3]!;
    if (word.startsWith('@') && word.length > 1)
      parsed.mentions.push(word.slice(1));
    else if (word.startsWith('-') && word.length > 1)
      parsed.excluded.push(word.slice(1));
    else parsed.words.push(word);
  }
  return parsed;
}

// One FTS5 phrase for a typed word: its tokens in order, quoted so nothing in
// it is syntax. Dutch glues words together ("tandartspraktijk"), so a word of
// three letters or more also matches longer words it starts.
export function ftsPhrase(word: string, prefix: boolean): string | null {
  const t = tokens(word);
  if (!t.length) return null;
  const last = t[t.length - 1]!;
  const star = prefix && last.length >= 2 ? '*' : '';
  return `"${t.join(' ')}"${star}`;
}

const SNIPPET_BEFORE = 50;
const SNIPPET_LENGTH = 180;

// The piece of a text around the first matched word, with every matched word
// marked. Words match at the start of a word, as the index does.
export function hitIn(
  field: SearchHit['field'],
  text: string,
  terms: readonly string[],
): SearchHit | null {
  if (!text || !terms.length) return null;
  const folded = fold(text);
  const found: [number, number][] = [];
  for (const term of terms) {
    if (!term) continue;
    let at = folded.indexOf(term);
    while (at >= 0) {
      const before = at === 0 ? '' : folded[at - 1]!;
      if (!/[\p{L}\p{N}]/u.test(before)) {
        let end = at + term.length;
        while (end < folded.length && /[\p{L}\p{N}]/u.test(folded[end]!)) end++;
        found.push([at, end - at]);
      }
      at = folded.indexOf(term, at + term.length);
    }
  }
  if (!found.length) return null;
  found.sort((a, b) => a[0] - b[0]);
  const first = found[0]![0];
  let start = Math.max(0, first - SNIPPET_BEFORE);
  if (start > 0) {
    const space = text.indexOf(' ', start);
    if (space >= 0 && space < first) start = space + 1;
  }
  let end = Math.min(text.length, start + SNIPPET_LENGTH);
  if (end < text.length) {
    const space = text.lastIndexOf(' ', end);
    if (space > first) end = space;
  }
  const raw = text.slice(start, end);
  // Line breaks and runs of spaces become one space; offsets follow.
  let out = start > 0 ? '…' : '';
  const map: number[] = [];
  let lastSpace = false;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    const space = /\s/.test(ch);
    if (space && lastSpace) {
      map.push(out.length - 1);
      continue;
    }
    map.push(out.length);
    out += space ? ' ' : ch;
    lastSpace = space;
  }
  map.push(out.length);
  if (end < text.length) out += '…';
  const ranges = found
    .filter(([at, len]) => at >= start && at + len <= end)
    .map(([at, len]): [number, number] => {
      const from = map[at - start]!;
      return [from, map[at - start + len]! - from];
    });
  return { field, text: out, ranges };
}

// Words that say nothing about which mail is meant, Dutch and English; a
// question typed before Enter is full of them.
export const FILLER = new Set(
  (
    'de het een en van in op te voor met aan is ik je jij u uw mijn me mij we wij ons ze zij hij haar hem die dat dit deze er ook nog wat wie waar wanneer hoe hoeveel waarom welke welk was waren ben bent zijn heb heeft hebben had hadden moest moet moeten kan kon kunnen zou zal wil wilde om tot bij uit door naar over als of maar niet geen al wel even mail mails bericht berichten ' +
    'the a an of to for and or is are was were my i me you your what when where how which who did do does from about with by on at it this that mail email message'
  ).split(' '),
);
