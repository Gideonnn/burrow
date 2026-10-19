import type { Access } from './access';
import type { Db } from './db';
import type { EventBus } from './events';
import type { Platform } from './platform';

export type PlatformEnv = {
  Variables: {
    db: Db;
    events: EventBus;
    platform: Platform;
    access: Access;
    // The person behind a verified Cloudflare Access login, on browser pages
    // served through the tunnel; absent everywhere else.
    loginPersonId?: string;
  };
};
