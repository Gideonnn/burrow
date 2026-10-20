import type { BotDefinition, SkillDefinition } from '@burrow/contracts';
import type { AgentRequest } from './agents/runner';

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

// What a bot needs for one run with these skills. Opus thinks at high effort;
// Haiku chooses its own.
export function botRequest(
  bot: BotDefinition,
  skills: SkillDefinition[],
): Pick<AgentRequest, 'model' | 'effort' | 'agent' | 'system'> {
  const model =
    bot.agent !== 'local' && skills.some((s) => s.model === 'opus')
      ? 'opus'
      : bot.model;
  return {
    model,
    agent: bot.agent,
    system: systemPrompt(bot, skills),
    ...(model === 'opus' ? { effort: 'high' as const } : {}),
  };
}

// Fences text someone else wrote, so a closing tag inside it cannot end the
// block early.
export function untrusted(tag: string, text: string): string {
  const closing = `</${tag}>`;
  return `<${tag}>\n${text.replaceAll(closing, `</${tag}_>`)}\n${closing}`;
}
