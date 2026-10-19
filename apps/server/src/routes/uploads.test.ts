import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

function household() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const token = h.key(gideon.id, ['read', 'organize']);
  const create = (size: number, key = token) =>
    h.call(key, '/api/uploads', {
      method: 'POST',
      body: JSON.stringify({ size }),
    });
  const put = (id: string, offset: number, bytes: string, key = token) =>
    h.call(key, `/api/uploads/${id}?offset=${offset}`, {
      method: 'PUT',
      headers: { 'content-type': 'application/octet-stream' },
      body: bytes,
    });
  return { ...h, gideon, eva, token, create, put };
}

describe('chunked uploads', () => {
  it('assemble a file from chunks that each say where they start', async () => {
    const h = household();
    const { id } = (await (await h.create(10)).json()) as { id: string };
    expect(await (await h.put(id, 0, 'hello')).json()).toMatchObject({
      received: 5,
      complete: false,
    });
    expect(await (await h.put(id, 5, 'world')).json()).toMatchObject({
      received: 10,
      complete: true,
    });
    const target = `${h.dataDir}/done.bin`;
    await h.platform.uploads.take(id, h.gideon.id, target);
    expect(await readFile(target, 'utf8')).toBe('helloworld');
  });

  it('refuse a chunk at the wrong offset, so a resumed upload never doubles bytes', async () => {
    const h = household();
    const { id } = (await (await h.create(10)).json()) as { id: string };
    await h.put(id, 0, 'hello');
    expect((await h.put(id, 0, 'hello')).status).toBe(400);
    expect(
      await (await h.call(h.token, `/api/uploads/${id}`)).json(),
    ).toMatchObject({
      received: 5,
    });
  });

  it('refuse more bytes than announced', async () => {
    const h = household();
    const { id } = (await (await h.create(4)).json()) as { id: string };
    expect((await h.put(id, 0, 'too long')).status).toBe(400);
    expect(
      await (await h.call(h.token, `/api/uploads/${id}`)).json(),
    ).toMatchObject({
      received: 0,
    });
  });

  it('belong to the person who started them', async () => {
    const h = household();
    const { id } = (await (await h.create(5)).json()) as { id: string };
    const eva = h.key(h.eva.id, ['read', 'organize']);
    expect((await h.put(id, 0, 'hello', eva)).status).toBe(404);
  });
});
