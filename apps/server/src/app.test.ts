import { healthResponse } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { loadConfig } from './config';
import { testHousehold } from './testing';

describe('GET /health', () => {
  it('answers with the health contract, without a key', async () => {
    const res = await testHousehold().app.request('/health');
    expect(res.status).toBe(200);
    expect(healthResponse.parse(await res.json())).toMatchObject({
      status: 'ok',
      service: 'burrow-server',
    });
  });
});

describe('loadConfig', () => {
  it('binds to localhost by default so nothing is exposed by accident', () => {
    expect(loadConfig({})).toMatchObject({ port: 4717, host: '127.0.0.1' });
  });

  it('keeps the database inside the data directory', () => {
    expect(loadConfig({ BURROW_DATA_DIR: '/srv/burrow' }).dbPath).toBe(
      '/srv/burrow/burrow.sqlite',
    );
  });

  it('rejects a port that is not a number', () => {
    expect(() => loadConfig({ BURROW_PORT: 'abc' })).toThrow();
  });
});
