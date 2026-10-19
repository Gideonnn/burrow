import { z } from 'zod';
import { apiKeySummary, person } from './access';

// The second half of the device login: the app trades the one-time code it
// received on its loopback address, plus its PKCE verifier, for a device key.
export const loginTokenRequest = z.object({
  code: z.string().min(20).max(200),
  verifier: z.string().min(43).max(128),
});
export type LoginTokenRequest = z.infer<typeof loginTokenRequest>;

export const loginTokenResponse = z.object({
  token: z.string(),
  key: apiKeySummary,
  person,
});
export type LoginTokenResponse = z.infer<typeof loginTokenResponse>;
