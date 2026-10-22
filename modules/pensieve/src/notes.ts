import type {
  MeetingNotes,
  RecordingKind,
  RecordingNotes,
} from '@burrow/contracts';
import { stamp } from './subtitles';

// Which skill writes the notes of each kind; dictation gets none.
export const NOTES_SKILLS = {
  call: 'meeting-notes',
  video: 'interview-notes',
  screen: 'screen-steps',
} as const satisfies Partial<Record<RecordingKind, string>>;

export const NOTES_TYPE = {
  call: 'meeting',
  video: 'interview',
  screen: 'steps',
} as const satisfies Record<keyof typeof NOTES_SKILLS, RecordingNotes['type']>;

export const hasNotes = (
  kind: RecordingKind,
): kind is keyof typeof NOTES_SKILLS => kind in NOTES_SKILLS;

// Section names follow the language the notes were written in; Dutch is what
// the household reads, everything else gets English headings.
const HEADINGS = {
  Dutch: {
    summary: 'Samenvatting',
    decisions: 'Besluiten',
    actions: 'Actiepunten',
    questions: 'Open vragen',
    core: 'Kern',
    quotes: 'Citaten',
    chapters: 'Hoofdstukken',
    steps: 'Stappen',
  },
  English: {
    summary: 'Summary',
    decisions: 'Decisions',
    actions: 'Action items',
    questions: 'Open questions',
    core: 'Core',
    quotes: 'Quotes',
    chapters: 'Chapters',
    steps: 'Steps',
  },
} as const;

// Notes written before they had a type are meeting notes.
export function typedNotes(
  notes: RecordingNotes | MeetingNotes | null | undefined,
): RecordingNotes | null {
  if (!notes) return null;
  return 'type' in notes ? notes : { ...notes, type: 'meeting' };
}

export function renderNotes(
  input: RecordingNotes | MeetingNotes,
  language: string,
): string {
  const notes = typedNotes(input)!;
  const h = language === 'Dutch' ? HEADINGS.Dutch : HEADINGS.English;
  const at = (seconds: number | null) =>
    seconds === null ? '' : ` (${stamp(seconds)})`;
  const parts: string[] = [];
  const list = (heading: string, items: string[]) => {
    if (items.length) parts.push(`## ${heading}\n\n${items.join('\n')}`);
  };
  switch (notes.type) {
    case 'meeting':
      parts.push(`## ${h.summary}\n\n${notes.summary.trim()}`);
      list(
        h.decisions,
        notes.decisions.map((d) => `- ${d}`),
      );
      list(
        h.actions,
        notes.actions.map((a) =>
          ['- [ ] ' + a.text, a.owner, a.due].filter(Boolean).join(' · '),
        ),
      );
      list(
        h.questions,
        notes.openQuestions.map((q) => `- ${q}`),
      );
      break;
    case 'interview':
      parts.push(`## ${h.core}\n\n${notes.summary.trim()}`);
      list(
        h.quotes,
        notes.quotes.map(
          (q) =>
            `- "${q.text}"${q.speaker ? ` (${q.speaker}${q.at === null ? '' : `, ${stamp(q.at)}`})` : at(q.at)}`,
        ),
      );
      list(
        h.chapters,
        notes.chapters.map(
          (c) => `- ${c.at === null ? '' : `${stamp(c.at)} `}${c.title}`,
        ),
      );
      break;
    case 'steps':
      parts.push(`## ${h.summary}\n\n${notes.summary.trim()}`);
      list(
        h.steps,
        notes.steps.map((s, i) => `${i + 1}. ${s.text}${at(s.at)}`),
      );
      break;
  }
  return `${parts.join('\n\n')}\n`;
}
