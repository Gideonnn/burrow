import type { SettingDefinition } from '@burrow/contracts';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { Hono } from 'hono';
import type { Access, AccessExtender } from './access';
import type { PlatformEnv } from './env';
import type { RestrictionCheck } from './people';
import type { TriggerType } from './workers/routines';
import type { SubjectType } from './workers/subjects';
import type { TaskKind } from './workers/tasks';

// An application on the platform (Hedwig, Pensieve). Everything is optional:
// a module contributes only what it has. Modules never import each other;
// they meet through subjects, routines and events.
export type Module = {
  name: string;
  settings?: SettingDefinition[];
  // Adds the module's part of the access (Hedwig: visible mailboxes).
  access?: AccessExtender;
  restrictions?: RestrictionCheck[];
  subjects?: SubjectType[];
  taskKinds?: TaskKind[];
  triggers?: TriggerType[];
  // Mounted under /api, behind the key check.
  api?: Hono<PlatformEnv>;
  // Mounted at the root; on the tunnel these pages need an Access login.
  browser?: Hono<PlatformEnv>;
  // Extra fields for GET /api/me, e.g. Hedwig's mailboxes.
  me?: (access: Access) => Record<string, unknown>;
  // Tools for agents on the MCP endpoint, registered per key.
  mcp?: (server: McpServer, access: Access) => void;
  // Native apps whose signed builds the server offers for updates.
  clients?: string[];
  // Background work (sync loops); returns a stop function.
  start?: () => (() => void) | void;
};
