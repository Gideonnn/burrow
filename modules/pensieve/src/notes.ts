import type { MeetingNotes } from '@burrow/contracts';

// Section names follow the language the notes were written in; Dutch is what
// the household reads, everything else gets English headings.
const HEADINGS = {
  Dutch: {
    summary: 'Samenvatting',
    decisions: 'Besluiten',
    actions: 'Actiepunten',
    questions: 'Open vragen',
  },
  English: {
    summary: 'Summary',
    decisions: 'Decisions',
    actions: 'Action items',
    questions: 'Open questions',
  },
} as const;

export function renderNotes(notes: MeetingNotes, language: string): string {
  const h = language === 'Dutch' ? HEADINGS.Dutch : HEADINGS.English;
  const parts = [`## ${h.summary}\n\n${notes.summary.trim()}`];
  if (notes.decisions.length) {
    parts.push(
      `## ${h.decisions}\n\n${notes.decisions.map((d) => `- ${d}`).join('\n')}`,
    );
  }
  if (notes.actions.length) {
    const line = (a: MeetingNotes['actions'][number]) =>
      ['- [ ] ' + a.text, a.owner, a.due].filter(Boolean).join(' · ');
    parts.push(`## ${h.actions}\n\n${notes.actions.map(line).join('\n')}`);
  }
  if (notes.openQuestions.length) {
    parts.push(
      `## ${h.questions}\n\n${notes.openQuestions.map((q) => `- ${q}`).join('\n')}`,
    );
  }
  return `${parts.join('\n\n')}\n`;
}
