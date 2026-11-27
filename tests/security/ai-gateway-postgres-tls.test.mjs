import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('AI gateway PostgreSQL TLS verifies certificates by default', async () => {
  const source = await readFile(new URL('../../server/ai_gateway.ts', import.meta.url), 'utf8');
  assert.match(source, /process\.env\.AI_DATABASE_SSL_REJECT_UNAUTHORIZED\s*!==\s*['"]false['"]/);
  assert.match(source, /ssl:\s*\{\s*rejectUnauthorized\s*\}/);
  assert.doesNotMatch(source, /ssl:\s*\{\s*rejectUnauthorized:\s*false\s*\}/);
});
