-- Atomic order creation: order, items, inventory reservation and coupon redemption
-- are committed together. Payment gateway integration remains separate.

CREATE TABLE IF NOT EXISTS public.zoal_order_inventory_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id text NOT NULL REFERENCES public.zoal_orders(id) ON DELETE CASCADE,
  inventory_id uuid NOT NULL REFERENCES public.zoal_inventory(id),
  product_id text NOT NULL,
  warehouse_id uuid,
  quantity integer NOT NULL CHECK (quantity > 0),
  created_at timestamptz NOT NULL DEFAULT NOW(),
  released_at timestamptz,
  consumed_at timestamptz,
  restocked_at timestamptz
);

-- Keep existing installations compatible when this migration is re-run.
ALTER TABLE public.zoal_order_inventory_reservations
  ADD COLUMN IF NOT EXISTS consumed_at timestamptz;
ALTER TABLE public.zoal_order_inventory_reservations
  ADD COLUMN IF NOT EXISTS restocked_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_order_inventory_reservations_order_product_active
  ON public.zoal_order_inventory_reservations(order_id, product_id, inventory_id)
  WHERE released_at IS NULL AND consumed_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_order_inventory_reservations_order
  ON public.zoal_order_inventory_reservations(order_id);

ALTER TABLE public.zoal_order_inventory_reservations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "order_inventory_reservations_service_only" ON public.zoal_order_inventory_reservations;
CREATE POLICY "order_inventory_reservations_service_only"
  ON public.zoal_order_inventory_reservations
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.create_order_atomic(
  p_order_id text,
  p_customer_id text,
  p_items jsonb,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_shipping_cost numeric,
  p_tax_amount numeric,
  p_total_amount numeric,
  p_coupon_id uuid DEFAULT NULL,
  p_coupon_code text DEFAULT NULL,
  p_coupon_discount numeric DEFAULT 0,
  p_payment_method text DEFAULT 'card',
  p_notes text DEFAULT '',
  p_order_data jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item record;
  v_inventory record;
  v_remaining integer;
  v_available integer;
  v_take integer;
  v_reserved jsonb := '[]'::jsonb;
  v_order jsonb;
BEGIN
  IF p_order_id IS NULL OR p_order_id = '' THEN
    RAISE EXCEPTION 'ORDER_ID_REQUIRED';
  END IF;

  IF p_customer_id IS NULL OR p_customer_id = '' THEN
    RAISE EXCEPTION 'CUSTOMER_ID_REQUIRED';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  IF p_subtotal < 0 OR p_discount_amount < 0 OR p_shipping_cost < 0
     OR p_tax_amount < 0 OR p_total_amount < 0 THEN
    RAISE EXCEPTION 'INVALID_ORDER_TOTALS';
  END IF;

  IF EXISTS (SELECT 1 FROM public.zoal_orders WHERE id = p_order_id) THEN
    RAISE EXCEPTION 'ORDER_ID_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.zoal_orders (
    id, customer_id, status, coupon_id, subtotal, discount_amount,
    shipping_cost, tax_amount, total_amount, payment_status,
    payment_method, notes, order_data
  )
  VALUES (
    p_order_id, p_customer_id, 'pending', p_coupon_id, p_subtotal,
    p_discount_amount, p_shipping_cost, p_tax_amount, p_total_amount,
    'unpaid', p_payment_method, p_notes, p_order_data
  )
  RETURNING to_jsonb(zoal_orders.*) INTO v_order;

  FOR v_item IN
    SELECT product_id, SUM(quantity)::integer AS quantity,
           MAX(unit_price)::numeric AS unit_price,
           MAX(unit_cost)::numeric AS unit_cost,
           SUM(total_price)::numeric AS total_price
    FROM jsonb_to_recordset(p_items) AS x(
      product_id text,
      quantity integer,
      unit_price numeric,
      unit_cost numeric,
      total_price numeric
    )
    GROUP BY product_id
    ORDER BY product_id
  LOOP
    IF v_item.product_id IS NULL OR v_item.product_id = '' OR v_item.quantity < 1 THEN
      RAISE EXCEPTION 'INVALID_ORDER_ITEM';
    END IF;

    IF v_item.unit_price IS NULL OR v_item.unit_price < 0
       OR v_item.total_price IS NULL OR v_item.total_price < 0 THEN
      RAISE EXCEPTION 'INVALID_ORDER_ITEM_PRICE';
    END IF;

    INSERT INTO public.zoal_order_items (
      order_id, product_id, quantity, unit_price, unit_cost, total_price
    )
    VALUES (
      p_order_id, v_item.product_id, v_item.quantity,
      v_item.unit_price, v_item.unit_cost, v_item.total_price
    );

    v_remaining := v_item.quantity;

    FOR v_inventory IN
      SELECT id, warehouse_id, quantity, reserved_quantity
      FROM public.zoal_inventory
      WHERE product_id = v_item.product_id
        AND quantity > reserved_quantity
      ORDER BY warehouse_id NULLS LAST, id
      FOR UPDATE
    LOOP
      EXIT WHEN v_remaining <= 0;

      v_available := GREATEST(v_inventory.quantity - v_inventory.reserved_quantity, 0);
      v_take := LEAST(v_remaining, v_available);

      IF v_take > 0 THEN
        UPDATE public.zoal_inventory
        SET reserved_quantity = reserved_quantity + v_take,
            updated_at = NOW()
        WHERE id = v_inventory.id;

        INSERT INTO public.zoal_order_inventory_reservations (
          order_id, inventory_id, product_id, warehouse_id, quantity
        ) VALUES (
          p_order_id, v_inventory.id, v_item.product_id, v_inventory.warehouse_id, v_take
        );

        v_reserved := v_reserved || jsonb_build_object(
          'product_id', v_item.product_id,
          'warehouse_id', v_inventory.warehouse_id,
          'quantity', v_take
        );

        v_remaining := v_remaining - v_take;
      END IF;
    END LOOP;

    IF v_remaining > 0 THEN
      RAISE EXCEPTION 'INSUFFICIENT_INVENTORY:%:%', v_item.product_id, v_item.quantity;
    END IF;
  END LOOP;

  IF p_coupon_id IS NOT NULL THEN
    PERFORM public.redeem_coupon_for_order(
      p_coupon_id,
      p_order_id,
      p_customer_id,
      COALESCE(p_coupon_discount, p_discount_amount)
    );
  END IF;

  RETURN jsonb_build_object(
    'order', v_order,
    'reserved', v_reserved
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_atomic(
  text, text, jsonb, numeric, numeric, numeric, numeric, numeric,
  uuid, text, numeric, text, text, jsonb
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_order_atomic(
  text, text, jsonb, numeric, numeric, numeric, numeric, numeric,
  uuid, text, numeric, text, text, jsonb
) TO service_role;


CREATE OR REPLACE FUNCTION public.release_order_inventory(
  p_order_id text,
  p_reason text DEFAULT 'cancelled'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r record;
  v_released integer := 0;
  v_order_status text;
BEGIN
  SELECT status INTO v_order_status
  FROM public.zoal_orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  IF v_order_status NOT IN ('cancelled','failed','pending','pending_payment','draft') THEN
    RAISE EXCEPTION 'ORDER_NOT_ELIGIBLE_FOR_RESERVATION_RELEASE:%', v_order_status;
  END IF;

  FOR r IN
    SELECT id, inventory_id, quantity
    FROM public.zoal_order_inventory_reservations
    WHERE order_id = p_order_id
      AND released_at IS NULL
    ORDER BY inventory_id
    FOR UPDATE
  LOOP
    UPDATE public.zoal_inventory
       SET reserved_quantity = GREATEST(reserved_quantity - r.quantity, 0),
           updated_at = NOW()
     WHERE id = r.inventory_id;

    UPDATE public.zoal_order_inventory_reservations
       SET released_at = NOW()
     WHERE id = r.id;

    v_released := v_released + r.quantity;
  END LOOP;

  RETURN jsonb_build_object('order_id', p_order_id, 'released_quantity', v_released, 'reason', p_reason);
END;
$$;

REVOKE ALL ON FUNCTION public.release_order_inventory(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_order_inventory(text,text) TO service_role;


-- Atomically cancel an order and release all ledger-backed reservations.
CREATE OR REPLACE FUNCTION public.cancel_order_and_release_inventory(
  p_order_id text,
  p_reason text DEFAULT 'cancelled'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r record;
  v_status text;
  v_released integer := 0;
BEGIN
  SELECT status INTO v_status
  FROM public.zoal_orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_status NOT IN ('draft','pending_payment','pending','processing') THEN
    RAISE EXCEPTION 'ORDER_NOT_ELIGIBLE_FOR_CANCELLATION:%', v_status;
  END IF;

  FOR r IN
    SELECT id, inventory_id, quantity
    FROM public.zoal_order_inventory_reservations
    WHERE order_id = p_order_id
      AND released_at IS NULL
    ORDER BY inventory_id
    FOR UPDATE
  LOOP
    UPDATE public.zoal_inventory
       SET reserved_quantity = GREATEST(reserved_quantity - r.quantity, 0),
           updated_at = NOW()
     WHERE id = r.inventory_id;

    UPDATE public.zoal_order_inventory_reservations
       SET released_at = NOW()
     WHERE id = r.id;

    v_released := v_released + r.quantity;
  END LOOP;

  UPDATE public.zoal_orders
     SET status = 'cancelled',
         updated_at = NOW()
   WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'status', 'cancelled',
    'released_quantity', v_released,
    'reason', p_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order_and_release_inventory(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_order_and_release_inventory(text,text) TO service_role;


-- Reserve inventory for legacy checkout paths while keeping the reservation ledger authoritative.
CREATE OR REPLACE FUNCTION public.reserve_order_inventory(
  p_order_id text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  item jsonb;
  v_product_id text;
  v_qty integer;
  v_inv public.zoal_inventory%ROWTYPE;
  v_reserved integer := 0;
BEGIN
  IF p_order_id IS NULL OR p_order_id = '' THEN RAISE EXCEPTION 'ORDER_ID_REQUIRED'; END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'ITEMS_REQUIRED'; END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := item->>'product_id';
    v_qty := (item->>'quantity')::integer;
    IF v_product_id IS NULL OR v_qty IS NULL OR v_qty < 1 THEN
      RAISE EXCEPTION 'INVALID_RESERVATION_ITEM';
    END IF;

    SELECT * INTO v_inv
    FROM public.zoal_inventory
    WHERE product_id = v_product_id
    ORDER BY warehouse_id NULLS LAST, id
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_NOT_FOUND:%', v_product_id; END IF;
    IF (v_inv.quantity - v_inv.reserved_quantity) < v_qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_INVENTORY:%', v_product_id;
    END IF;

    UPDATE public.zoal_inventory
       SET reserved_quantity = reserved_quantity + v_qty,
           updated_at = NOW()
     WHERE id = v_inv.id;

    INSERT INTO public.zoal_order_inventory_reservations
      (order_id, inventory_id, product_id, warehouse_id, quantity)
    VALUES
      (p_order_id, v_inv.id, v_product_id, v_inv.warehouse_id, v_qty);

    v_reserved := v_reserved + v_qty;
  END LOOP;

  RETURN jsonb_build_object('order_id', p_order_id, 'reserved_quantity', v_reserved);
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_order_inventory(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_order_inventory(text,jsonb) TO service_role;


-- Atomically restock physical inventory when a paid order is cancelled/refunded.
-- Restock only reservation ledger rows consumed by a successful payment.
-- restocked_at makes the operation idempotent across webhook retries.
CREATE OR REPLACE FUNCTION public.restock_paid_order_inventory(
  p_order_id text,
  p_reason text DEFAULT 'cancelled'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r record;
  v_restocked integer := 0;
  v_payment_status text;
  v_ledger_count integer := 0;
  v_unconsumed_count integer := 0;
  v_inventory_id uuid;
BEGIN
  SELECT payment_status
    INTO v_payment_status
    FROM public.zoal_orders
   WHERE id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_payment_status IS NULL OR v_payment_status NOT IN ('paid', 'refunded', 'partially_refunded') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAID_OR_REFUNDED';
  END IF;

  SELECT count(*)
    INTO v_ledger_count
    FROM public.zoal_order_inventory_reservations
   WHERE order_id = p_order_id;

  -- Legacy paid orders created before the reservation ledger existed:
  -- record their historical stock return target once, so retries are safe.
  IF v_ledger_count = 0 THEN
    FOR r IN
      SELECT product_id, SUM(quantity)::integer AS quantity
        FROM public.zoal_order_items
       WHERE order_id = p_order_id
       GROUP BY product_id
       ORDER BY product_id
    LOOP
      SELECT id
        INTO v_inventory_id
        FROM public.zoal_inventory
       WHERE product_id = r.product_id
       ORDER BY warehouse_id NULLS LAST, id
       LIMIT 1
       FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_CONTEXT_MISSING:%', r.product_id;
      END IF;

      INSERT INTO public.zoal_order_inventory_reservations
        (order_id, inventory_id, product_id, warehouse_id, quantity, consumed_at)
      SELECT p_order_id, i.id, r.product_id, i.warehouse_id, r.quantity, NOW()
        FROM public.zoal_inventory i
       WHERE i.id = v_inventory_id;
    END LOOP;
  ELSE
    SELECT count(*)
      INTO v_unconsumed_count
      FROM public.zoal_order_inventory_reservations
     WHERE order_id = p_order_id
       AND released_at IS NULL
       AND consumed_at IS NULL;

    IF v_unconsumed_count > 0 THEN
      RAISE EXCEPTION 'ORDER_RESERVATIONS_NOT_CONSUMED';
    END IF;
  END IF;

  FOR r IN
    SELECT reservation.id, reservation.inventory_id, reservation.quantity
      FROM public.zoal_order_inventory_reservations AS reservation
     WHERE reservation.order_id = p_order_id
       AND reservation.released_at IS NULL
       AND reservation.consumed_at IS NOT NULL
       AND reservation.restocked_at IS NULL
     ORDER BY reservation.inventory_id, reservation.id
     FOR UPDATE
  LOOP
    UPDATE public.zoal_inventory
       SET quantity = quantity + r.quantity,
           updated_at = NOW()
     WHERE id = r.inventory_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_ROW_MISSING_FOR_RESERVATION:%', r.id;
    END IF;

    UPDATE public.zoal_order_inventory_reservations
       SET restocked_at = NOW()
     WHERE id = r.id
       AND restocked_at IS NULL;

    IF FOUND THEN
      v_restocked := v_restocked + r.quantity;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'restocked_quantity', v_restocked,
    'already_restocked', (v_restocked = 0),
    'reason', p_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.restock_paid_order_inventory(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.restock_paid_order_inventory(text,text) TO service_role;

-- Consume the exact inventory rows reserved for this order. This supports
-- reservations split across warehouses and prevents consuming another order's
-- reservation when a ledger record exists.
CREATE OR REPLACE FUNCTION public.finalize_order_payment(
  p_order_id TEXT,
  p_gateway_payment_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order RECORD;
  v_tx RECORD;
  v_item RECORD;
  v_reservation RECORD;
  v_inventory RECORD;
  v_ledger_count integer;
  v_active_reserved integer;
  v_consumed_count integer;
  v_remaining integer;
  v_take integer;
BEGIN
  SELECT id, payment_status
    INTO v_order
    FROM public.zoal_orders
   WHERE id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.payment_status = 'paid' THEN
    RETURN jsonb_build_object('status', 'already_paid', 'order_id', p_order_id);
  END IF;

  SELECT id, gateway_payment_id, payment_status
    INTO v_tx
    FROM public.zoal_payment_transactions
   WHERE order_id = p_order_id
   ORDER BY created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_TRANSACTION_NOT_FOUND';
  END IF;

  IF v_tx.gateway_payment_id IS NOT NULL
     AND v_tx.gateway_payment_id <> p_gateway_payment_id THEN
    RAISE EXCEPTION 'GATEWAY_PAYMENT_MISMATCH';
  END IF;

  IF v_tx.payment_status NOT IN ('initiated', 'pending', 'unpaid') THEN
    IF v_tx.payment_status = 'paid' THEN
      RETURN jsonb_build_object('status', 'already_paid', 'order_id', p_order_id);
    END IF;
    RAISE EXCEPTION 'PAYMENT_NOT_SETTLEABLE';
  END IF;

  FOR v_item IN
    SELECT product_id, SUM(quantity)::integer AS quantity
      FROM public.zoal_order_items
     WHERE order_id = p_order_id
     GROUP BY product_id
     ORDER BY product_id
  LOOP
    SELECT count(*),
           COALESCE(sum(quantity) FILTER (
             WHERE released_at IS NULL AND consumed_at IS NULL
           ), 0)::integer
      INTO v_ledger_count, v_active_reserved
      FROM public.zoal_order_inventory_reservations
     WHERE order_id = p_order_id
       AND product_id = v_item.product_id;

    IF v_ledger_count > 0 THEN
      IF v_active_reserved <> v_item.quantity THEN
        RAISE EXCEPTION 'RESERVATION_LEDGER_MISMATCH:%:expected=%:reserved=%',
          v_item.product_id, v_item.quantity, v_active_reserved;
      END IF;

      FOR v_reservation IN
        SELECT id, inventory_id, quantity
          FROM public.zoal_order_inventory_reservations
         WHERE order_id = p_order_id
           AND product_id = v_item.product_id
           AND released_at IS NULL
           AND consumed_at IS NULL
         ORDER BY inventory_id, id
         FOR UPDATE
      LOOP
        SELECT quantity, reserved_quantity
          INTO v_inventory
          FROM public.zoal_inventory
         WHERE id = v_reservation.inventory_id
         FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'INVENTORY_ROW_MISSING_FOR_RESERVATION:%', v_reservation.id;
        END IF;
        IF v_inventory.quantity < v_reservation.quantity
           OR v_inventory.reserved_quantity < v_reservation.quantity THEN
          RAISE EXCEPTION 'INVENTORY_RESERVATION_INVALID:%', v_item.product_id;
        END IF;

        UPDATE public.zoal_inventory
           SET quantity = quantity - v_reservation.quantity,
               reserved_quantity = reserved_quantity - v_reservation.quantity,
               updated_at = NOW()
         WHERE id = v_reservation.inventory_id;

        UPDATE public.zoal_order_inventory_reservations
           SET consumed_at = NOW()
         WHERE id = v_reservation.id;
      END LOOP;
    ELSE
      -- Compatibility path for orders created before the reservation ledger.
      -- Allocate their aggregate reservation across warehouses without
      -- requiring one warehouse to hold the entire order quantity.
      v_remaining := v_item.quantity;

      FOR v_inventory IN
        SELECT id, quantity, reserved_quantity
          FROM public.zoal_inventory
         WHERE product_id = v_item.product_id
           AND reserved_quantity > 0
         ORDER BY warehouse_id NULLS LAST, id
         FOR UPDATE
      LOOP
        EXIT WHEN v_remaining = 0;
        v_take := LEAST(v_remaining, v_inventory.reserved_quantity);

        IF v_inventory.quantity < v_take THEN
          RAISE EXCEPTION 'INVENTORY_BELOW_RESERVED_QUANTITY:%', v_item.product_id;
        END IF;

        UPDATE public.zoal_inventory
           SET quantity = quantity - v_take,
               reserved_quantity = reserved_quantity - v_take,
               updated_at = NOW()
         WHERE id = v_inventory.id;

        v_remaining := v_remaining - v_take;
      END LOOP;

      IF v_remaining > 0 THEN
        RAISE EXCEPTION 'INVENTORY_RESERVATION_NOT_FOUND_FOR_PRODUCT:%', v_item.product_id;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.zoal_payment_transactions
     SET payment_status = 'paid',
         gateway_payment_id = p_gateway_payment_id,
         updated_at = NOW()
   WHERE id = v_tx.id;

  UPDATE public.zoal_orders
     SET payment_status = 'paid',
         status = 'processing',
         updated_at = NOW()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('status', 'paid', 'order_id', p_order_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_order_payment(
  p_order_id TEXT,
  p_gateway_payment_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order RECORD;
  v_tx RECORD;
  v_item RECORD;
  v_reservation RECORD;
  v_inventory RECORD;
  v_ledger_count integer;
  v_active_reserved integer;
  v_remaining integer;
  v_take integer;
BEGIN
  SELECT id, payment_status
    INTO v_order
    FROM public.zoal_orders
   WHERE id = p_order_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  SELECT id, gateway_payment_id, payment_status
    INTO v_tx
    FROM public.zoal_payment_transactions
   WHERE order_id = p_order_id
   ORDER BY created_at DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_TRANSACTION_NOT_FOUND';
  END IF;

  IF p_gateway_payment_id IS NOT NULL
     AND v_tx.gateway_payment_id IS NOT NULL
     AND v_tx.gateway_payment_id <> p_gateway_payment_id THEN
    RAISE EXCEPTION 'GATEWAY_PAYMENT_MISMATCH';
  END IF;

  IF v_tx.payment_status = 'failed'
     AND v_order.payment_status = 'failed' THEN
    RETURN jsonb_build_object('status', 'already_failed', 'order_id', p_order_id);
  END IF;

  IF v_tx.payment_status IN ('paid', 'refunded', 'partially_refunded') THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_SETTLED';
  END IF;

  FOR v_item IN
    SELECT product_id, SUM(quantity)::integer AS quantity
      FROM public.zoal_order_items
     WHERE order_id = p_order_id
     GROUP BY product_id
     ORDER BY product_id
  LOOP
    SELECT count(*),
           COALESCE(sum(quantity) FILTER (
             WHERE released_at IS NULL AND consumed_at IS NULL
           ), 0)::integer
      INTO v_ledger_count, v_active_reserved
      FROM public.zoal_order_inventory_reservations
     WHERE order_id = p_order_id
       AND product_id = v_item.product_id;

    IF v_ledger_count > 0 THEN
      IF v_active_reserved = 0 THEN
        SELECT count(*)
          INTO v_consumed_count
          FROM public.zoal_order_inventory_reservations
         WHERE order_id = p_order_id
           AND product_id = v_item.product_id
           AND released_at IS NULL
           AND consumed_at IS NOT NULL;
        IF v_consumed_count > 0 THEN
          RAISE EXCEPTION 'RESERVATION_ALREADY_CONSUMED_FOR_UNPAID_ORDER:%', v_item.product_id;
        END IF;
        CONTINUE;
      END IF;
      IF v_active_reserved <> v_item.quantity THEN
        RAISE EXCEPTION 'RESERVATION_LEDGER_MISMATCH:%:expected=%:reserved=%',
          v_item.product_id, v_item.quantity, v_active_reserved;
      END IF;

      FOR v_reservation IN
        SELECT id, inventory_id, quantity
          FROM public.zoal_order_inventory_reservations
         WHERE order_id = p_order_id
           AND product_id = v_item.product_id
           AND released_at IS NULL
           AND consumed_at IS NULL
         ORDER BY inventory_id, id
         FOR UPDATE
      LOOP
        SELECT reserved_quantity
          INTO v_inventory
          FROM public.zoal_inventory
         WHERE id = v_reservation.inventory_id
         FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'INVENTORY_ROW_MISSING_FOR_RESERVATION:%', v_reservation.id;
        END IF;
        IF v_inventory.reserved_quantity < v_reservation.quantity THEN
          RAISE EXCEPTION 'INVENTORY_RESERVATION_INVALID:%', v_item.product_id;
        END IF;

        UPDATE public.zoal_inventory
           SET reserved_quantity = reserved_quantity - v_reservation.quantity,
               updated_at = NOW()
         WHERE id = v_reservation.inventory_id;

        UPDATE public.zoal_order_inventory_reservations
           SET released_at = NOW()
         WHERE id = v_reservation.id;
      END LOOP;
    ELSE
      -- Legacy aggregate reservations: release across warehouses.
      v_remaining := v_item.quantity;

      FOR v_inventory IN
        SELECT id, reserved_quantity
          FROM public.zoal_inventory
         WHERE product_id = v_item.product_id
           AND reserved_quantity > 0
         ORDER BY warehouse_id NULLS LAST, id
         FOR UPDATE
      LOOP
        EXIT WHEN v_remaining = 0;
        v_take := LEAST(v_remaining, v_inventory.reserved_quantity);

        UPDATE public.zoal_inventory
           SET reserved_quantity = reserved_quantity - v_take,
               updated_at = NOW()
         WHERE id = v_inventory.id;

        v_remaining := v_remaining - v_take;
      END LOOP;

      IF v_remaining > 0 THEN
        RAISE EXCEPTION 'INVENTORY_RESERVATION_NOT_FOUND_FOR_PRODUCT:%', v_item.product_id;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.zoal_payment_transactions
     SET payment_status = 'failed',
         gateway_payment_id = COALESCE(p_gateway_payment_id, gateway_payment_id),
         updated_at = NOW()
   WHERE id = v_tx.id;

  UPDATE public.zoal_orders
     SET payment_status = 'failed',
         status = 'failed',
         updated_at = NOW()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('status', 'failed', 'order_id', p_order_id);
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_order_payment(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_order_payment(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_order_payment(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.fail_order_payment(TEXT, TEXT) TO service_role;

