import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['src/main.ts', 'src/cli.ts'],
  format: ['esm'],
  target: 'node22',
  platform: 'node',
  clean: true,
  // Workspace packages export TS source, so the server bundle must inline
  // them; node_modules dependencies stay external.
  noExternal: [/^@burrow\//],
  // The bundle resolves migrations next to itself (dist/migrations).
  onSuccess: 'cp -R src/db/migrations dist/migrations',
});
