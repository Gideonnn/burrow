import type { TaskResult } from '@burrow/contracts';
import {
  listPeople,
  type Platform,
  type StandingWork,
  type TaskKind,
  type TaskRow,
} from '@burrow/platform';
import { and, count, desc, eq, inArray, isNull, notInArray } from 'drizzle-orm';
import { z } from 'zod';
import { FACTS_FEATURE } from './facts/service';
import { Recent } from './memo';
import { mailboxes, messageFacts, messages, messageVectors } from './schema';
import { DIMS, type VectorIndex } from './vectors';

// embeddinggemma: multilingual, 300M parameters, about 75 mails a second on
// a MacBook. Against Haiku-written questions about real mail it found the
// mail as well as bge-m3 at twice the speed, and its first 256 numbers keep
// most of the meaning.
export const EMBED_MODEL = 'ollama:embeddinggemma';
const BATCH = 64;
const FOLDERS = ['inbox', 'archive', 'sent'] as const;

const embedAnswer = z.object({ vectors: z.array(z.array(z.number())) });

// What a message means, for the model: subject, sender, the facts' summary
// or else the start of the body, and the search words.
function embedText(
  m: {
    subject: string;
    from: { name?: string | null; email: string };
    bodyText: string | null;
  },
  f: { summary: string | null; keywords: string[] } | null,
) {
  const body =
    f?.summary ?? (m.bodyText ?? '').replace(/\s+/g, ' ').slice(0, 400);
  const words = f?.keywords.length ? `\n${f.keywords.join(', ')}` : '';
  return `title: ${m.subject} | text: ${m.subject}\nVan: ${m.from.name || m.from.email}\n${body}${words}`;
}

// Search by meaning needs every message as a vector. The runner on the
// owner's Mac makes them with Ollama, sixty-four at a time, newest first, for
// people who let their mail be indexed; nothing leaves the Mac but numbers.
export class EmbeddingsService {
  // Vectors a runner sent, held from accepting the answer until applying it.
  private readonly pending = new Map<string, number[][]>();
  private readonly progress = new Recent<{ waiting: number; done: number }>(
    30_000,
  );

  constructor(
    private readonly platform: Platform,
    private readonly vectors: VectorIndex,
  ) {}

  private get db() {
    return this.platform.db;
  }

  private waiting(personId: string, scope?: readonly string[]) {
    return and(
      eq(mailboxes.ownerId, personId),
      scope ? inArray(messages.mailboxId, [...scope]) : undefined,
      inArray(messages.folder, [...FOLDERS]),
      isNull(messageVectors.messageId),
    );
  }

  private people() {
    return listPeople(this.db)
      .map((p) => p.id)
      .filter((id) => this.platform.settings.enabled(id, FACTS_FEATURE));
  }

  private work: StandingWork = {
    people: () => this.people(),
    progress: (personId) => {
      if (!this.platform.settings.enabled(personId, FACTS_FEATURE)) {
        return { waiting: 0, done: null };
      }
      return this.progress.get(personId, () => {
        const base = this.db
          .select({ n: count() })
          .from(messages)
          .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
          .leftJoin(messageVectors, eq(messageVectors.messageId, messages.id));
        const waiting = base.where(this.waiting(personId)).get()!.n;
        const done = this.db
          .select({ n: count() })
          .from(messageVectors)
          .innerJoin(messages, eq(messages.id, messageVectors.messageId))
          .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
          .where(eq(mailboxes.ownerId, personId))
          .get()!.n;
        return { waiting, done };
      });
    },
    next: (personId, running, access) => {
      if (!this.platform.settings.enabled(personId, FACTS_FEATURE))
        return undefined;
      const held = running.flatMap((t) => ids(t));
      const scope = access?.restrictions.mailboxes
        ? access.mailboxIds
        : undefined;
      const rows = this.db
        .select({ id: messages.id })
        .from(messages)
        .innerJoin(mailboxes, eq(mailboxes.id, messages.mailboxId))
        .leftJoin(messageVectors, eq(messageVectors.messageId, messages.id))
        .where(
          and(
            this.waiting(personId, scope),
            held.length ? notInArray(messages.id, held) : undefined,
          ),
        )
        .orderBy(desc(messages.receivedAt))
        .limit(BATCH)
        .all();
      return rows.length
        ? { input: { ids: rows.map((r) => r.id) } }
        : undefined;
    },
  };

  private request(task: TaskRow) {
    const wanted = ids(task);
    const rows = wanted.length
      ? this.db
          .select({
            m: messages,
            f: {
              summary: messageFacts.summary,
              keywords: messageFacts.keywords,
            },
          })
          .from(messages)
          .leftJoin(messageFacts, eq(messageFacts.messageId, messages.id))
          .where(inArray(messages.id, wanted))
          .all()
      : [];
    const byId = new Map(rows.map((r) => [r.m.id, r]));
    const texts = wanted.map((id) => {
      const r = byId.get(id);
      return r
        ? embedText(
            r.m,
            r.f ? { summary: r.f.summary, keywords: r.f.keywords ?? [] } : null,
          )
        : '';
    });
    return {
      model: EMBED_MODEL,
      agent: 'local' as const,
      embed: true,
      system: '',
      prompt: JSON.stringify({ texts, dims: DIMS }),
      schema: {},
    };
  }

  kinds(): TaskKind[] {
    return [
      {
        name: 'hedwig.embed',
        title: 'Zoeken op betekenis',
        queue: 'local',
        // Above mail facts, which always has work: a piece of sixty-four mails
        // takes a second, so the whole archive is done before Winky misses it.
        priority: 'normal',
        model: EMBED_MODEL,
        standing: this.work,
        describe: (t) => ({
          title: `Zoeken op betekenis (${ids(t).length} mails)`,
        }),
        agent: {
          request: (t) => this.request(t),
          accept: (t, raw): TaskResult => {
            const { vectors } = embedAnswer.parse(raw);
            if (vectors.length !== ids(t).length)
              throw new Error('wrong number of vectors');
            this.pending.set(t.id, vectors);
            return {
              summary: `${vectors.length} mails`,
              fields: {},
              ops: [],
              draft: null,
            };
          },
        },
        apply: async (t) => {
          const vectors = this.pending.get(t.id);
          this.pending.delete(t.id);
          if (!vectors) return;
          const list = ids(t);
          this.db.transaction(() => {
            list.forEach((id, i) => {
              const v = vectors[i];
              // A message deleted while the Mac worked has nothing to attach to.
              if (
                v?.length &&
                this.db
                  .select({ id: messages.id })
                  .from(messages)
                  .where(eq(messages.id, id))
                  .get()
              ) {
                this.vectors.store(EMBED_MODEL, id, v);
              }
            });
          });
        },
      },
    ];
  }
}

function ids(task: TaskRow): string[] {
  const input = task.input as { ids?: unknown } | null;
  return Array.isArray(input?.ids)
    ? input.ids.filter((x): x is string => typeof x === 'string')
    : [];
}
