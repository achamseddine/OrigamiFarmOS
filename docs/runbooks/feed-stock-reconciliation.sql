-- Feed stock reconciliation (v0.8.4). Read-only; runs on PostgreSQL and SQLite.
-- Every query returns NO ROWS on a consistent database. Procedure and meaning:
-- docs/runbooks/FEED-STOCK-RECONCILIATION.md. The same checks, per product,
-- are GET /feed-inventory/integrity and `python -m app.feed_stock_integrity`.

-- Q1. Stock line (inventory_items.current_qty) ≠ the sum of all its movements.
SELECT 'Q1' AS q, p.id AS feed_product_id, p.name, i.current_qty AS stock_line,
       COALESCE(SUM(CASE WHEN t.direction = 'in' THEN t.quantity ELSE -t.quantity END), 0) AS ledger
FROM feed_products p
JOIN inventory_items i ON i.id = p.inventory_item_id
LEFT JOIN inventory_transactions t ON t.item_id = i.id
GROUP BY p.id, p.name, i.current_qty
HAVING ABS(i.current_qty - COALESCE(SUM(CASE WHEN t.direction = 'in' THEN t.quantity ELSE -t.quantity END), 0)) > 0.001;

-- Q2. A lot whose stored quantity ≠ the sum of its movements, or below zero.
SELECT 'Q2' AS q, l.feed_product_id, l.lot_code, l.quantity_on_hand AS stored,
       COALESCE(SUM(CASE WHEN t.direction = 'in' THEN t.quantity ELSE -t.quantity END), 0) AS ledger
FROM feed_lots l
LEFT JOIN inventory_transactions t ON t.lot_id = l.id
GROUP BY l.id, l.feed_product_id, l.lot_code, l.quantity_on_hand
HAVING ABS(l.quantity_on_hand - COALESCE(SUM(CASE WHEN t.direction = 'in' THEN t.quantity ELSE -t.quantity END), 0)) > 0.001
    OR l.quantity_on_hand < -0.001;

-- Q3. Stock with no lot that no open exception explains: the no-lot balance
--     is above zero, or differs from − Σ open exceptions.
SELECT 'Q3' AS q, u.feed_product_id, u.untraced_balance, COALESCE(o.open_qty, 0) AS open_exceptions
FROM (SELECT p.id AS feed_product_id,
             COALESCE(SUM(CASE WHEN t.direction = 'in' THEN t.quantity ELSE -t.quantity END), 0) AS untraced_balance
      FROM feed_products p
      LEFT JOIN inventory_transactions t ON t.item_id = p.inventory_item_id AND t.lot_id IS NULL
      GROUP BY p.id) u
LEFT JOIN (SELECT feed_product_id, SUM(quantity - resolved_quantity) AS open_qty
           FROM feed_stock_exceptions WHERE status = 'open' GROUP BY feed_product_id) o
       ON o.feed_product_id = u.feed_product_id
WHERE u.untraced_balance > 0.001 OR ABS(u.untraced_balance + COALESCE(o.open_qty, 0)) > 0.001;

-- Q4. A movement with no lot and no exception, posted once the feed had
--     lots, that is not an opening-balance carry-over, a count, or the
--     v0.8.4 migration's carry-over: an issue that bypassed the ledger rules.
SELECT 'Q4' AS q, t.id, t.created_at, t.direction, t.quantity, t.reason, p.name
FROM inventory_transactions t
JOIN feed_products p ON p.inventory_item_id = t.item_id
WHERE t.lot_id IS NULL AND t.stock_exception_id IS NULL
  AND t.reason NOT IN ('opening_balance', 'count_correction', 'ledger_carry_over')
  AND t.created_at >= (SELECT MIN(l.created_at) FROM feed_lots l WHERE l.feed_product_id = p.id);

-- Q5. An override exception that does not name who recorded it, who
--     approved it, or why. (legacy_untraced rows, found by the migration,
--     have no approver by design: it was not recorded before v0.8.4.)
SELECT 'Q5' AS q, e.id, e.feed_product_id, e.quantity, e.requested_by, e.approved_by, e.reason
FROM feed_stock_exceptions e
WHERE e.kind = 'untraced_issue'
  AND (e.requested_by IS NULL OR e.approved_by IS NULL OR e.reason IS NULL OR TRIM(e.reason) = '');

-- Q6. Exceptions still open (not an error: the manager's work list).
SELECT 'Q6' AS q, e.feed_product_id, e.kind, e.quantity - e.resolved_quantity AS open_qty, e.occurred_at, e.reason
FROM feed_stock_exceptions e
WHERE e.status = 'open'
ORDER BY e.occurred_at;
