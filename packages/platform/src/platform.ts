import type { SettingDefinition } from '@burrow/contracts';
import { eq } from 'drizzle-orm';
import type { AccessExtender } from './access';
import { type AgentRunner, LimitedRunner } from './agents/runner';
import type { Catalog } from './catalog/loadCatalog';
import type { Db } from './db';
import { EventBus } from './events';
import { Files, Uploads } from './files';
import type { Module } from './module';
import { person, type RestrictionCheck } from './people';
import { instructions } from './schema';
import { Settings } from './settings';
import { Shares } from './shares';
import { type OwnerContext, Routines } from './workers/routines';
import { Subjects } from './workers/subjects';
import { Workers } from './workers/tasks';

export type PlatformOptions = {
  db: Db;
  dataDir: string;
  publicUrl: string;
  catalog: Catalog;
  runner: AgentRunner;
  // The language bots write in when a person did not choose one.
  language?: string;
  // Server tasks at once, and agent runs at once across everything.
  workers?: number;
  agents?: number;
  // The agent CLIs the server runs, for its entry in the runner list.
  agentNames?: string[];
  events?: EventBus;
};

const LANGUAGES = [
  { value: 'Dutch', label: 'Nederlands' },
  { value: 'English', label: 'English' },
];

const platformSettings: SettingDefinition[] = [
  {
    key: 'language',
    module: 'platform',
    label: 'Taal van de bots',
    description:
      'De taal waarin bots redenen, samenvattingen en notulen schrijven.',
    type: 'choice',
    options: LANGUAGES,
    default: null,
    feature: false,
  },
  {
    key: 'platform.shareCloudWork',
    module: 'platform',
    label: 'Mijn cloudtaken mogen ook op andere Macs in huis draaien',
    description:
      'Taken voor een cloud-AI, zonder geheimen en persoonsnummers, mogen dan ook op de Mac van een huisgenoot lopen.',
    type: 'boolean',
    default: false,
    feature: false,
    personal: true,
  },
];

// What every module builds on: people, settings, shares, files, the task queue
// with its workers, routines, and the agents. The server creates one, adds the
// modules with use(), then serves the result.
export class Platform {
  readonly db: Db;
  readonly events: EventBus;
  readonly settings: Settings;
  readonly shares: Shares;
  readonly files: Files;
  readonly uploads: Uploads;
  readonly subjects = new Subjects();
  readonly workers: Workers;
  readonly routines: Routines;
  readonly catalog: Catalog;
  readonly runner: AgentRunner;
  readonly publicUrl: string;
  readonly language: string;
  readonly modules: Module[] = [];
  readonly accessExtenders: AccessExtender[] = [];
  readonly restrictionChecks: RestrictionCheck[] = [];

  constructor(o: PlatformOptions) {
    this.db = o.db;
    this.events = o.events ?? new EventBus();
    this.catalog = o.catalog;
    this.runner = new LimitedRunner(o.runner, o.agents ?? 2);
    this.publicUrl = o.publicUrl;
    this.language = o.language ?? 'English';
    this.settings = new Settings(o.db);
    this.settings.declare(platformSettings);
    this.shares = new Shares(o.db);
    this.files = new Files(o.dataDir);
    this.uploads = new Uploads(o.db, o.dataDir);
    this.workers = new Workers({
      db: o.db,
      events: this.events,
      subjects: this.subjects,
      runner: this.runner,
      concurrency: o.workers ?? 2,
      agents: o.agentNames,
      sharesCloudWork: (personId) =>
        this.settings.enabled(personId, 'platform.shareCloudWork'),
    });
    this.routines = new Routines({
      db: o.db,
      catalog: o.catalog,
      workers: this.workers,
      subjects: this.subjects,
      owner: (personId) => this.owner(personId),
    });
  }

  use(module: Module): this {
    if (this.modules.some((m) => m.name === module.name)) {
      throw new Error(`module "${module.name}" is added twice`);
    }
    this.settings.declare(module.settings ?? []);
    for (const s of module.subjects ?? []) this.subjects.register(s);
    for (const k of module.taskKinds ?? []) this.workers.register(k);
    for (const t of module.triggers ?? []) this.routines.registerTrigger(t);
    if (module.access) this.accessExtenders.push(module.access);
    this.restrictionChecks.push(...(module.restrictions ?? []));
    this.modules.push(module);
    return this;
  }

  // Who a bot works for: name, standing instructions and language.
  owner(personId: string): OwnerContext {
    const row = person(this.db, personId);
    if (!row) throw new Error('unknown person');
    const language = this.settings.get(personId, 'language');
    return {
      name: row.name,
      instructions: this.instructions(personId),
      language: typeof language === 'string' ? language : this.language,
    };
  }

  instructions(personId: string): string {
    return (
      this.db
        .select()
        .from(instructions)
        .where(eq(instructions.personId, personId))
        .get()?.text ?? ''
    );
  }

  setInstructions(personId: string, text: string) {
    this.db
      .insert(instructions)
      .values({ personId, text })
      .onConflictDoUpdate({ target: instructions.personId, set: { text } })
      .run();
  }

  get clients(): string[] {
    return this.modules.flatMap((m) => m.clients ?? []);
  }

  // Starts the workers and every module's background work; returns a stop.
  start(): () => void {
    this.workers.recover();
    const stops = this.modules.map((m) => m.start?.());
    const timer = setInterval(() => this.tick(), 60_000);
    timer.unref();
    return () => {
      clearInterval(timer);
      for (const stop of stops) stop?.();
    };
  }

  tick(now = new Date()) {
    this.routines.tick(now);
    this.workers.tick(now);
    void this.uploads.sweep(now);
  }
}
