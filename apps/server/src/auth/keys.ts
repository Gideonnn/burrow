import { createHash, randomBytes } from 'node:crypto';

const TOKEN_PREFIX = 'bk_';

export type NewToken = {
  token: string;
  hash: string;
  prefix: string;
};

export function generateToken(): NewToken {
  const token = TOKEN_PREFIX + randomBytes(32).toString('base64url');
  return { token, hash: hashToken(token), prefix: token.slice(0, 10) };
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
