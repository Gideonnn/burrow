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

// A skill is a folder in skills/ with a SKILL.md, in the Claude skill format.
export const skillDefinition = z.object({
  name: slug,
  description: z.string().min(1),
  instructions: z.string().min(1),
});
export type SkillDefinition = z.infer<typeof skillDefinition>;

// A bot is a persona defined in one markdown file: front matter for settings,
// the body for its character and standing instructions.
export const botDefinition = z.object({
  name: slug,
  displayName: z.string().min(1),
  description: z.string().min(1),
  model: z.enum(['haiku', 'sonnet', 'opus']).default('haiku'),
  skills: z.array(slug).default([]),
  // Agents never get `send` or `admin`: sending is a user action and admin
  // manages keys. See AGENTS.md, "Safety rules for agents in the product".
  rights: z
    .array(right.exclude(['send', 'admin']))
    .min(1)
    .default(['read']),
  persona: z.string().min(1),
});
export type BotDefinition = z.infer<typeof botDefinition>;
