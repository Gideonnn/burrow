import type {
  SettingDefinition,
  SettingValue,
  SettingsValues,
} from '@burrow/contracts';
import { eq } from 'drizzle-orm';
import type { Db } from './db';
import { people } from './schema';

export class SettingsError extends Error {}

// The settings every module declares, and each person's values. Values not
// set fall back to the declared default.
export class Settings {
  private readonly definitions = new Map<string, SettingDefinition>();

  constructor(private readonly db: Db) {}

  declare(definitions: readonly SettingDefinition[]) {
    for (const d of definitions) {
      if (this.definitions.has(d.key)) {
        throw new SettingsError(`setting "${d.key}" is declared twice`);
      }
      this.definitions.set(d.key, d);
    }
  }

  schema(): SettingDefinition[] {
    return [...this.definitions.values()];
  }

  values(personId: string): SettingsValues {
    const stored = this.stored(personId);
    return Object.fromEntries(
      this.schema().map((d) => [d.key, stored[d.key] ?? d.default]),
    );
  }

  get(personId: string, name: string): SettingValue {
    const definition = this.definitions.get(name);
    if (!definition) throw new SettingsError(`unknown setting "${name}"`);
    return this.stored(personId)[name] ?? definition.default;
  }

  enabled(personId: string, name: string): boolean {
    return this.get(personId, name) === true;
  }

  // null resets a setting to its default.
  update(personId: string, changes: SettingsValues): SettingsValues {
    const next = { ...this.stored(personId) };
    for (const [name, value] of Object.entries(changes)) {
      const d = this.definitions.get(name);
      if (!d) throw new SettingsError(`unknown setting "${name}"`);
      if (value === null) {
        delete next[name];
        continue;
      }
      const ok =
        d.type === 'boolean'
          ? typeof value === 'boolean'
          : d.type === 'choice'
            ? typeof value === 'string' &&
              (d.options ?? []).some((o) => o.value === value)
            : typeof value === 'string' && value.length <= 10_000;
      if (!ok) throw new SettingsError(`invalid value for "${name}"`);
      next[name] = value;
    }
    this.db
      .update(people)
      .set({ settings: next })
      .where(eq(people.id, personId))
      .run();
    return this.values(personId);
  }

  private stored(personId: string): SettingsValues {
    return (
      this.db
        .select({ settings: people.settings })
        .from(people)
        .where(eq(people.id, personId))
        .get()?.settings ?? {}
    );
  }
}
