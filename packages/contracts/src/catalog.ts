import { z } from 'zod';

export const right = z.enum([
  'read',
  'organize',
  'draft',
  'send',
  'tasks',
  'admin',
]);
export type Right = z.infer<typeof right>;

const slug = z
  .string()
  .regex(/^[a-z][a-z0-9-]*$/, 'use lowercase letters, digits and dashes');

const cloudModel = z.enum(['haiku', 'opus']);
// A model on the owner's own Mac through Ollama, for bots on the local queue.
const localModel = z.string().regex(/^ollama:.+/);
export const effort = z.enum(['low', 'medium', 'high', 'xhigh', 'max']);
export type Effort = z.infer<typeof effort>;

// A skill is a folder in skills/ with a SKILL.md, in the Claude skill format.
export const skillDefinition = z.object({
  name: slug,
  description: z.string().min(1),
  // Set when the skill needs more than the bot's own model.
  model: cloudModel.optional(),
  instructions: z.string().min(1),
});
export type SkillDefinition = z.infer<typeof skillDefinition>;

// A bot is a persona defined in one markdown file: front matter for settings,
// the body for its character and standing instructions.
export const botDefinition = z
  .object({
    name: slug,
    displayName: z.string().min(1),
    description: z.string().min(1),
    model: z.union([cloudModel, localModel]).default('haiku'),
    // The agent CLI this bot prefers; the others are the fallback. Bots that
    // read untrusted input should prefer claude, which runs without tools.
    // A local bot runs only on its owner's Mac and never falls back.
    agent: z.enum(['claude', 'codex', 'any', 'local']).default('any'),
    skills: z.array(slug).default([]),
    // Agents never get `send` or `admin`: sending is a user action and admin
    // manages keys. See AGENTS.md, "Safety rules for agents in the product".
    rights: z
      .array(right.exclude(['send', 'admin']))
      .min(1)
      .default(['read']),
    persona: z.string().min(1),
  })
  .refine(
    (bot) => (bot.agent === 'local') === bot.model.startsWith('ollama:'),
    {
      message:
        'a local bot needs a local model (ollama:<name>), and only a local bot may use one',
    },
  );
export type BotDefinition = z.infer<typeof botDefinition>;
