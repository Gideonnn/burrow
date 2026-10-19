import { routineInput, settingsValues } from '@burrow/contracts';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { Access } from './access';
import type { Platform } from './platform';

export const mcpText = (value: unknown) => ({
  content: [
    {
      type: 'text' as const,
      text: typeof value === 'string' ? value : JSON.stringify(value, null, 2),
    },
  ],
});
export const mcpRefusal = (message: string) => ({
  ...mcpText(message),
  isError: true,
});

// Tools every key gets, about the person behind it: their settings, bot
// instructions, routines and tasks. Logins, keys and approving a task are
// left out on purpose: those stay with the person.
export function registerPlatformTools(
  server: McpServer,
  platform: Platform,
  access: Access,
) {
  const can = (right: string) => access.rights.has(right as never);
  const me = access.personId;

  if (can('read')) {
    server.registerTool(
      'get_settings',
      {
        description:
          'The settings and features of the person behind this key, with what each one means and its current value.',
      },
      async () =>
        mcpText({
          values: platform.settings.values(me),
          schema: platform.settings.schema(),
        }),
    );
    server.registerTool(
      'list_tasks',
      {
        description:
          'Recent tasks the bots did or are doing for this person, newest first, with their status and result.',
        inputSchema: {
          kind: z.string().optional().describe('e.g. routine'),
          limit: z.number().int().min(1).max(100).optional(),
        },
      },
      async ({ kind, limit }) =>
        mcpText(
          platform.workers.list(access, {
            kinds: kind ? [kind] : undefined,
            limit: limit ?? 20,
          }),
        ),
    );
    server.registerTool(
      'list_routines',
      { description: 'The routines (triggers that start bot tasks).' },
      async () => mcpText(platform.routines.list(me)),
    );
    server.registerTool(
      'get_instructions',
      {
        description:
          "The person's standing instructions for every bot that works for them.",
      },
      async () => mcpText(platform.instructions(me)),
    );
  }

  if (can('organize')) {
    server.registerTool(
      'update_settings',
      {
        description:
          'Change settings of the person behind this key. Use get_settings for the keys and allowed values; null resets one to its default.',
        inputSchema: { values: settingsValues },
      },
      async ({ values }) => {
        try {
          return mcpText(platform.settings.update(me, values));
        } catch (error) {
          return mcpRefusal((error as Error).message);
        }
      },
    );
    server.registerTool(
      'set_instructions',
      {
        description:
          "Replace the person's standing instructions for their bots (plain language).",
        inputSchema: { text: z.string().max(10_000) },
      },
      async ({ text }) => {
        platform.setInstructions(me, text);
        return mcpText('saved');
      },
    );
    server.registerTool(
      'save_routine',
      {
        description:
          'Create a routine, or replace one when id is given. A routine runs a bot with one skill when its trigger fires.',
        inputSchema: { id: z.string().optional(), routine: routineInput },
      },
      async ({ id, routine }) => {
        try {
          return mcpText(
            id
              ? platform.routines.update(me, id, routine)
              : platform.routines.create(me, routine),
          );
        } catch (error) {
          return mcpRefusal((error as Error).message);
        }
      },
    );
    server.registerTool(
      'delete_routine',
      { description: 'Delete a routine.', inputSchema: { id: z.string() } },
      async ({ id }) =>
        platform.routines.remove(me, id)
          ? mcpText('deleted')
          : mcpRefusal('unknown routine'),
    );
  }
}
