import type { BotDefinition, SkillDefinition } from '@burrow/contracts';

// The bot's persona followed by exactly the skills this run needs, so
// instructions for other jobs cannot leak in.
export function systemPrompt(
  bot: BotDefinition,
  skills: SkillDefinition[],
): string {
  return [
    bot.persona,
    ...skills.map((s) => `# Skill: ${s.name}\n\n${s.instructions}`),
  ].join('\n\n');
}

// Fences text someone else wrote, so a closing tag inside it cannot end the
// block early.
export function untrusted(tag: string, text: string): string {
  const closing = `</${tag}>`;
  return `<${tag}>\n${text.replaceAll(closing, `</${tag}_>`)}\n${closing}`;
}
