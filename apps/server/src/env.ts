import type { Access } from './auth/access';
import type { Db } from './db/client';

export type AppEnv = {
  Variables: {
    db: Db;
    access: Access;
  };
};
