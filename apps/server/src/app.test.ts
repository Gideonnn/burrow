import { healthResponse } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { createApp } from './app';
import { loadConfig } from './config';

describe('GET /health', () => {
  it('answers with the health contract', async () => {
    const res = await createApp({ version: '1.2.3' }).request('/health');
    expect(res.status).toBe(200);
    expect(healthResponse.parse(await res.json())).toEqual({
      status: 'ok',
      service: 'burrow-server',
      version: '1.2.3',
    });
  });
});

describe('loadConfig', () => {
  it('binds to localhost by default so nothing is exposed by accident', () => {
    expect(loadConfig({})).toEqual({ port: 4717, host: '127.0.0.1' });
  });

  it('rejects a port that is not a number', () => {
    expect(() => loadConfig({ BURROW_PORT: 'abc' })).toThrow();
  });
});
