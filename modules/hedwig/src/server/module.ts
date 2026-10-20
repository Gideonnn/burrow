import type {
  RoutineTrigger,
  SettingDefinition,
  TriageDecision,
} from '@burrow/contracts';
import type { Module, Platform } from '@burrow/platform';
import { inArray } from 'drizzle-orm';
import { mailboxAccess, mailboxRestriction } from './access';
import type { Accounts } from './accounts';
import { createDraft } from './drafts';
import { InsightsService, LONG_MESSAGE } from './insights';
import { type ClientFor, MailService, type MessageRow } from './mail-service';
import { registerHedwigTools } from './mcp-tools';
import { triagePrompt } from './prompt';
import { mailboxColumns, hedwigRoutes } from './routes';
import { connectRoutes } from './routes-connect';
import { startSyncLoop } from './scheduler';
import { mailboxes } from './schema';
import { SearchService } from './search';
import { TriageService } from './triage';

const RETRY_EVERY_MS = 10 * 60_000;

const settings: SettingDefinition[] = [
  {
    key: 'hedwig.enabled',
    module: 'hedwig',
    label: 'Hedwig (mail)',
    description: 'Mail lezen, sorteren en beantwoorden.',
    type: 'boolean',
    default: true,
    feature: true,
  },
  {
    key: 'hedwig.triage',
    module: 'hedwig',
    label: 'Mail laten sorteren',
    description:
      'Kreacher zet spam en ruis uit de inbox; jij controleert het onder Gefilterd.',
    type: 'boolean',
    default: true,
    feature: true,
  },
  {
    key: 'hedwig.insights',
    module: 'hedwig',
    label: 'Samenvattingen en antwoordvoorstellen',
    description:
      'Een korte samenvatting bij lange mail en kant-en-klare antwoorden.',
    type: 'boolean',
    default: true,
    feature: true,
  },
];

export type HedwigOptions = {
  // Turns a stored mailbox into a provider client; Accounts.clientFor in
  // production, fakes in tests.
  clientFor: ClientFor;
  // Without accounts the server cannot connect new OAuth mailboxes.
  accounts?: Accounts;
  bot: string;
  // Poll the providers; off in tests.
  sync?: boolean;
  // Replaces what happens to newly arrived mail (triage); for tests.
  onArrived?: (messageIds: string[]) => void;
};

type MessageFacts = { message: MessageRow; decision: TriageDecision };

// Hedwig, the mail module: providers, sync, the bot's triage and
// suggestions, drafts, and the "message" subject and trigger for routines.
export function hedwigModule(platform: Platform, options: HedwigOptions) {
  const { db } = platform;
  const mail = new MailService(db, options.clientFor, platform.events);
  const insights = new InsightsService({ platform, mail, bot: options.bot });
  const search = new SearchService({ platform, bot: options.bot });
  const triage = new TriageService({
    platform,
    mail,
    bot: options.bot,
    // Suggestions are ready by the time someone opens mail that needs an
    // answer, and long mail gets its summary up front.
    onDecided: (messageId, decision) => {
      const message = mail.message(messageId);
      if (!message) return;
      const owner = mail.mailbox(message.mailboxId)!.ownerId;
      const long = (message.bodyText ?? '').length > LONG_MESSAGE;
      if (
        (decision.action.kind === 'needs-reply' || long) &&
        platform.settings.enabled(owner, 'hedwig.insights')
      ) {
        insights.prefetch(messageId);
      }
      platform.routines.fire(
        'message',
        owner,
        { type: 'message', id: messageId },
        { message, decision } satisfies MessageFacts,
      );
    },
  });
  const onArrived =
    options.onArrived ?? ((ids: string[]) => void triage.enqueue(ids));
  const connect = options.accounts
    ? connectRoutes(options.accounts, mail, onArrived)
    : undefined;

  const api = hedwigRoutes({
    mail,
    triage,
    insights,
    search,
    onArrived,
  });
  if (connect) api.route('/', connect.api);

  const module: Module = {
    name: 'hedwig',
    settings,
    access: mailboxAccess,
    restrictions: [mailboxRestriction],
    api,
    browser: connect?.browser,
    clients: ['hedwig'],
    me: (access) => ({
      mailboxes: access.mailboxIds.length
        ? db
            .select(mailboxColumns)
            .from(mailboxes)
            .where(inArray(mailboxes.id, [...access.mailboxIds]))
            .orderBy(mailboxes.createdAt, mailboxes.address)
            .all()
        : [],
    }),
    mcp: (server, access) => registerHedwigTools(server, access, { db, mail }),
    subjects: [
      {
        type: 'message',
        visible: (access, id) => {
          const message = mail.message(id);
          return Boolean(
            message && access.mailboxIds.includes(message.mailboxId),
          );
        },
        prompt: (id, ctx) => {
          const message = mail.message(id);
          if (!message) return undefined;
          const box = mail.mailbox(message.mailboxId)!;
          return triagePrompt({
            ownerName: ctx.ownerName,
            instructions: ctx.instructions,
            mailboxInstructions: box.instructions,
            rules: [],
            mailbox: { address: box.address, provider: box.provider },
            message,
            ownerWroteToSender: false,
            language: ctx.language,
            task: ctx.task,
          });
        },
        apply: async (id, result, task) => {
          const message = mail.message(id);
          if (!message) return;
          if (result.ops.length) await mail.apply(message.id, result.ops);
          if (result.draft) {
            createDraft(
              db,
              {
                keyId: 'routine',
                keyName: platform.workers.toTask(task).title,
                personId: task.personId,
                rights: new Set(['draft']),
                restrictions: {},
                mailboxIds: [message.mailboxId],
              },
              {
                mailboxId: message.mailboxId,
                cc: [],
                inReplyTo: message.id,
                ...result.draft,
              },
            );
          }
        },
      },
    ],
    triggers: [
      {
        kind: 'message',
        matches: (trigger, facts) => matches(trigger, facts as MessageFacts),
      },
    ],
    start: () => {
      if (options.sync === false) return;
      const stopSync = startSyncLoop(mail, onArrived);
      void triage.retryUntriaged();
      const retry = setInterval(
        () => void triage.retryUntriaged(),
        RETRY_EVERY_MS,
      );
      retry.unref();
      return () => {
        stopSync();
        clearInterval(retry);
      };
    },
  };

  return { module, mail, triage, insights, onArrived };
}

function matches(
  trigger: RoutineTrigger,
  { message, decision }: MessageFacts,
): boolean {
  if (trigger.kind !== 'message') return false;
  const lower = (s: string) => s.toLowerCase();
  if (trigger.triage && trigger.triage !== decision.action.kind) return false;
  if (trigger.label) {
    const labels = [
      ...message.labels,
      ...(decision.action.kind === 'label' ? [decision.action.label] : []),
    ];
    if (!labels.some((l) => lower(l) === lower(trigger.label!))) return false;
  }
  if (
    trigger.from &&
    !lower(`${message.from.name ?? ''} ${message.from.email}`).includes(
      lower(trigger.from),
    )
  ) {
    return false;
  }
  if (
    trigger.subject &&
    !lower(message.subject).includes(lower(trigger.subject))
  )
    return false;
  return true;
}
