import { z } from 'zod';

export const settingValue = z.union([z.boolean(), z.string(), z.null()]);
export type SettingValue = z.infer<typeof settingValue>;

// A setting a module offers per person. Clients render these generically, so a
// new module's switches appear in every app without a client change. A
// feature is an on/off switch for a whole capability ("Pensieve", "triage").
export const settingDefinition = z.object({
  key: z.string().regex(/^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)*$/),
  module: z.string().min(1),
  label: z.string().min(1),
  description: z.string().optional(),
  type: z.enum(['boolean', 'choice', 'text']),
  options: z
    .array(z.object({ value: z.string(), label: z.string() }))
    .optional(),
  default: settingValue,
  feature: z.boolean().default(false),
  // Only the person changes it, never a household admin for them.
  personal: z.boolean().optional(),
});
export type SettingDefinition = z.infer<typeof settingDefinition>;

export const settingsValues = z.record(z.string(), settingValue);
export type SettingsValues = z.infer<typeof settingsValues>;

export const updateSettingsRequest = z.object({ values: settingsValues });
export type UpdateSettingsRequest = z.infer<typeof updateSettingsRequest>;
