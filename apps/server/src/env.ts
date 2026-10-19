import type { Access } from './auth/access';
import type { Db } from './db/client';
import type { EventBus } from './events';
import type { MailService } from './mail/service';

export type AppEnv = {
  Variables: {
    db: Db;
    mail: MailService;
    events: EventBus;
    // Called with the ids of messages that just arrived in an inbox; triage
    // hooks in here.
    onArrived: (messageIds: string[]) => void;
    access: Access;
  };
};
