import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const app = fs.readFileSync(new URL('../../app.ts', import.meta.url), 'utf8');
const security = fs.readFileSync(new URL('../../backend/security.ts', import.meta.url), 'utf8');
const workflow = fs.readFileSync(new URL('../../.github/workflows/repair-brands-crud.yml', import.meta.url), 'utf8');

test('WhatsApp webhook captures raw body before sanitization and verifies HMAC', () => {
  assert.match(app, /verify:\s*\(req: any, _res, buf\) =>[\s\S]*?req\.rawBody = Buffer\.from\(buf\)/);
  assert.match(app, /!\/\^sha256=\[0-9a-f\]\{64\}\$\/i\.test\(signature\)/);
  assert.match(app, /createHmac\('sha256', appSecret\)\.update\(rawBody\)\.digest\(\)/);
  assert.match(app, /supplied\.length !== expected\.length \|\| !timingSafeEqual\(supplied, expected\)/);
});

test('only the HMAC-authenticated WhatsApp webhook bypasses CSRF origin checks', () => {
  assert.match(security, /req\.path === '\/api\/webhooks\/whatsapp'/);
});

test('CI installs the committed dependency lockfile reproducibly', () => {
  assert.match(workflow, /run:\s*npm ci/);
  assert.doesNotMatch(workflow, /npm install --package-lock=false/);
});
