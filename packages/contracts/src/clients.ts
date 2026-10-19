import { z } from 'zod';

// A build of a native client, published by the operator and signed with the
// release key whose public half is compiled into the client.
export const clientRelease = z.object({
  version: z.number().int().positive(),
  size: z.number().int().positive(),
  sha256: z.string().regex(/^[0-9a-f]{64}$/),
  // Ed25519 over the zip, base64.
  signature: z.string().min(1),
  publishedAt: z.string(),
});
export type ClientRelease = z.infer<typeof clientRelease>;
