// Prints the release metadata for a zipped Hedwig build, signed with the
// release key in HEDWIG_RELEASE_KEY (Ed25519, PKCS#8 DER in base64):
//   node scripts/sign-release.mjs build/Hedwig-123.zip 123
// The public key goes to stderr so the release script can compare it with
// the one compiled into Hedwig.
import {
  createHash,
  createPrivateKey,
  createPublicKey,
  sign,
} from 'node:crypto';
import { readFileSync } from 'node:fs';

const [zipPath, version] = process.argv.slice(2);
const secret = process.env.HEDWIG_RELEASE_KEY;
if (!zipPath || !version || !secret) {
  console.error(
    'usage: HEDWIG_RELEASE_KEY=… node sign-release.mjs <zip> <version>',
  );
  process.exit(1);
}
const key = createPrivateKey({
  key: Buffer.from(secret, 'base64'),
  format: 'der',
  type: 'pkcs8',
});
const zip = readFileSync(zipPath);
const publicKey = createPublicKey(key)
  .export({ type: 'spki', format: 'der' })
  .subarray(-32);
console.error(publicKey.toString('base64'));
console.log(
  JSON.stringify({
    version: Number(version),
    size: zip.length,
    sha256: createHash('sha256').update(zip).digest('hex'),
    signature: sign(null, zip, key).toString('base64'),
    publishedAt: new Date().toISOString(),
  }),
);
