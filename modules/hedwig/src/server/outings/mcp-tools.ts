import { createOutingRequest, type Outing } from '@burrow/contracts';
import {
  type Access,
  mcpRefusal as refusal,
  mcpText as text,
} from '@burrow/platform';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { OutingError, type OutingsService } from './service';

// What an agent sees of an outing: never the tickets themselves, and only
// the mails its key may read.
const forAgent = (o: Outing) => ({
  ...o,
  tickets: o.tickets.map(({ id, holder, personalised }) => ({
    id,
    holder,
    personalised,
  })),
  mails: o.mails.filter((m) => m.visible),
});

// The household's outings for agents ("zet zaterdag het etentje bij Sanne
// erin"). Adding is allowed; deleting and tickets stay with people.
export function registerOutingTools(
  server: McpServer,
  access: Access,
  outings: OutingsService,
) {
  const can = (right: string) => access.rights.has(right as never);
  if (can('read')) {
    server.registerTool(
      'list_outings',
      {
        description:
          "List the household's outings (concerts, plays, festivals, parties) with their dates, venue, checklist and how many tickets are stored. Shared by everyone in the household.",
      },
      async () => text(outings.list(access).map(forAgent)),
    );
  }
  if (can('organize')) {
    server.registerTool(
      'add_outing',
      {
        description:
          "Add an outing the household goes to. Times are ISO 8601 with a time zone. It is shared with everyone in the household, who see that this key's person added it.",
        inputSchema: createOutingRequest.omit({
          messageId: true,
          attachmentIds: true,
        }).shape,
      },
      async (input) => {
        try {
          return text(forAgent(await outings.create(access, input)));
        } catch (error) {
          if (error instanceof OutingError) return refusal(error.message);
          throw error;
        }
      },
    );
  }
}
