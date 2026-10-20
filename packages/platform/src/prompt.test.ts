import type { BotDefinition, SkillDefinition } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { botRequest } from './prompt';

const kreacher: BotDefinition = {
  name: 'kreacher',
  displayName: 'Kreacher',
  description: 'Sorts.',
  model: 'haiku',
  agent: 'claude',
  skills: ['tidy', 'notes'],
  rights: ['read'],
  persona: 'You are Kreacher.',
};
const tidy: SkillDefinition = {
  name: 'tidy',
  description: 'Tidies.',
  instructions: 'Put things away.',
};
const notes: SkillDefinition = { ...tidy, name: 'notes', model: 'opus' };

describe('botRequest', () => {
  it('runs simple skills on the bot model without a fixed effort', () => {
    expect(botRequest(kreacher, [tidy])).toMatchObject({
      model: 'haiku',
      agent: 'claude',
    });
    expect(botRequest(kreacher, [tidy]).effort).toBeUndefined();
  });

  it('runs a skill that needs Opus on Opus at high effort', () => {
    expect(botRequest(kreacher, [notes])).toMatchObject({
      model: 'opus',
      effort: 'high',
    });
  });

  it('keeps a local bot on its local model', () => {
    const winky = {
      ...kreacher,
      model: 'ollama:gemma4',
      agent: 'local' as const,
    };
    expect(botRequest(winky, [notes])).toMatchObject({
      model: 'ollama:gemma4',
      agent: 'local',
    });
    expect(botRequest(winky, [notes]).effort).toBeUndefined();
  });
});
