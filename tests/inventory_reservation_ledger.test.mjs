import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(
  new URL('../migrations/066_atomic_order_creation.sql', import.meta.url),
  'utf8'
);

function sqlFunction(name) {
  const start = migration.indexOf(`CREATE OR REPLACE FUNCTION public.${name}(`);
  assert.notEqual(start, -1, `missing SQL function: ${name}`);
  const end = migration.indexOf('\n$$;', start);
  assert.notEqual(end, -1, `missing SQL function terminator: ${name}`);
  return migration.slice(start, end + 4);
}

test('reservation ledger tracks consumption and one-time restock state', () => {
  assert.match(migration, /ADD COLUMN IF NOT EXISTS consumed_at timestamptz/i);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS restocked_at timestamptz/i);
});

test('payment finalization consumes the order-specific reservation rows across warehouses', () => {
  const fn = sqlFunction('finalize_order_payment');
  assert.match(fn, /FOR v_reservation IN[\s\S]*?order_id = p_order_id[\s\S]*?product_id = v_item\.product_id/i);
  assert.match(fn, /WHERE id = v_reservation\.inventory_id/i);
  assert.match(fn, /SET consumed_at = NOW\(\)/i);
  assert.match(fn, /v_active_reserved <> v_item\.quantity/i);
  assert.match(fn, /sum\(quantity\) FILTER[\s\S]*?released_at IS NULL AND consumed_at IS NULL/i);
  assert.match(fn, /ORDER BY inventory_id, id[\s\S]*?FOR UPDATE/i);
  assert.match(fn, /reserved_quantity >= v_item\.quantity/i);
});

test('failed payments release the matching reservation ledger rows', () => {
  const fn = sqlFunction('fail_order_payment');
  assert.match(fn, /WHERE id = v_reservation\.inventory_id/i);
  assert.match(fn, /SET released_at = NOW\(\)/i);
  assert.match(fn, /RESERVATION_LEDGER_MISMATCH/i);
});

test('paid-order restock is idempotent and only restores consumed, not-yet-restocked rows', () => {
  const fn = sqlFunction('restock_paid_order_inventory');
  assert.match(fn, /consumed_at IS NOT NULL/i);
  assert.match(fn, /restocked_at IS NULL/i);
  assert.match(fn, /SET restocked_at = NOW\(\)/i);
  assert.match(fn, /FOR UPDATE/i);
  assert.match(fn, /already_restocked/i);
  assert.doesNotMatch(fn, /LEAST\(max_stock/i);
});

test('legacy aggregate reservations fail closed unless one row owns the full reservation', () => {
  const finalize = sqlFunction('finalize_order_payment');
  const fail = sqlFunction('fail_order_payment');
  assert.match(finalize, /reserved_quantity >= v_item\.quantity/i);
  assert.match(finalize, /LEGACY_INVENTORY_RESERVATION_NOT_FOUND/i);
  assert.match(finalize, /consumed_at\)[\s\S]*?v_inventory\.warehouse_id[\s\S]*?v_item\.quantity/i);
  assert.match(fail, /reserved_quantity >= v_item\.quantity/i);
  assert.match(fail, /LEGACY_INVENTORY_RESERVATION_NOT_FOUND/i);
  assert.match(fail, /released_at\)[\s\S]*?v_inventory\.warehouse_id[\s\S]*?v_item\.quantity/i);
});
