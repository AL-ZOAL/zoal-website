import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('AI provider status route requires owner/admin authorization', async () => {
  const source = await readFile(new URL('../../app.ts', import.meta.url), 'utf8');
  const route = source.match(/app\.get\(['"]\/api\/ai\/gateway\/status['"],([\s\S]*?)\);/);

  assert.ok(route, 'AI provider status route must be registered');
  assert.match(
    route[1],
    /authenticateRequest\s*,\s*requireRole\(\[['"]owner['"],\s*['"]admin['"]\]\)\s*,\s*getAIProviderStatus/,
    'status route must authenticate and restrict access to owner/admin'
  );
});
