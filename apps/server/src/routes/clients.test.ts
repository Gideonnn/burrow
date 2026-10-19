import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { clientRelease } from '@burrow/contracts';
import { afterEach, describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

const dirs: string[] = [];
afterEach(async () => {
  for (const dir of dirs.splice(0)) await rm(dir, { recursive: true });
});

async function household(publish = true) {
  const dir = await mkdtemp(join(tmpdir(), 'burrow-clients-'));
  dirs.push(dir);
  if (publish) {
    await mkdir(join(dir, 'hedwig'));
    await writeFile(join(dir, 'hedwig', '42.zip'), 'zip bytes');
    await writeFile(
      join(dir, 'hedwig', 'latest.json'),
      JSON.stringify({
        version: 42,
        size: 9,
        sha256: 'a'.repeat(64),
        signature: 'c2ln',
        publishedAt: '2026-10-19T20:00:00.000Z',
      }),
    );
  }
  const h = testHousehold({ clientsDir: dir });
  const token = h.key(h.person('Gideon').id, ['read']);
  return { ...h, token };
}

describe('client releases', () => {
  it('tell a client the latest signed build', async () => {
    const h = await household();
    const res = await h.call(h.token, '/api/clients/hedwig/latest');
    expect(clientRelease.parse(await res.json()).version).toBe(42);
  });

  it('serve the build itself', async () => {
    const h = await household();
    const res = await h.call(h.token, '/api/clients/hedwig/42.zip');
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('zip bytes');
  });

  it('answer 404 before anything is published, and for unknown or odd names', async () => {
    const empty = await household(false);
    expect(
      (await empty.call(empty.token, '/api/clients/hedwig/latest')).status,
    ).toBe(404);
    const h = await household();
    for (const path of [
      '/api/clients/hedwig/41.zip',
      '/api/clients/hedwig/..%2Flatest.json',
      '/api/clients/finch/latest',
    ]) {
      expect((await h.call(h.token, path)).status).toBe(404);
    }
  });

  it('need a key', async () => {
    const h = await household();
    expect((await h.app.request('/api/clients/hedwig/latest')).status).toBe(
      401,
    );
  });
});
