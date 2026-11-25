"""Feed stock integrity: one ledger, explicit stock exceptions (v0.8.4).

Revision ID: d6f8a0c2e4b7
Revises: c4e6a8b0d2f5
Create Date: 2026-11-25

Audit 2026-11-25, I-1 / I-2 / I-13. Until now a feed issue that named a
lot holding too little took the rest from no lot without any override, and
an approved override took the stock line below the lots for good. From
this revision the rows are the stock (database/INVENTORY-SCHEMA §1):

    lot balance      = Σ movements naming the lot           (never < 0)
    untraced balance = Σ movements of the item naming none   (never > 0)
    stock line       = Σ every movement = lots + untraced

and every kilo issued with no lot belongs to an open stock exception that
names who recorded it, who approved it and why, until it is reconciled.

Schema
- feed_stock_exceptions (new).
- inventory_transactions.stock_exception_id (nullable FK) tags the
  untraced movement and the one that reconciles it.
- inventory_transactions.actor_user_id (nullable): who posted a movement.

Data — per feed product. Nothing is deleted or edited: no
stored stock line changes, no lot changes (except one held below zero, see
3), no existing movement is touched. What the stored figures held without
a movement behind them is made explicit by NEW movements, each pair sharing
a correlation id and `linked_entity_type = 'inventory_migration'`:

1. A lot whose stored quantity differs from the sum of its movements (an
   opening balance carried from the stock line before v0.8.4, or a figure
   set by the demo seed) gets the difference as a `ledger_carry_over`
   movement on the lot, paired with the opposite movement on no lot — the
   lot's figure is kept and now has its rows; the stock line is unchanged.
2. A stock line that differs from the sum of all its movements gets the
   difference as one `ledger_carry_over` movement on no lot — the stored
   figure is kept and now has its row.
3. A lot held below zero (a correction that took it there) is brought to
   zero by a carry-over pair: the shortfall moves to the no-lot balance,
   where step 4 makes it an exception naming that lot. The stock line is
   unchanged.
4. Then the no-lot balance:
   - above zero (stock on record with no lot): carried into a new lot
     `<code>-CARRIED` (`<code>-OPENING` for a feed with no lot yet) by a
     pair, like an opening balance;
   - below zero (stock issued with no lot before v0.8.4): one open
     `legacy_untraced` exception for the whole gap, listing every movement
     with no lot since the feed's first lot (id, date, quantity, reason,
     what it was for) and the lots that were below zero. Approval was not
     recorded before v0.8.4, so `approved_by` is empty and the reason says
     so; the manager reconciles it like any other exception.

After this revision every feed product passes GET /feed-inventory/integrity;
the migration test (tests/test_feed_stock_migration.py) builds the four
cases above at the previous revision and checks it, and the stored stock
lines, on SQLite and PostgreSQL 16.

Downgrade drops the table and the two columns. The movements posted here
stay: they are history, and they net to zero on every stock line.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op

revision = "d6f8a0c2e4b7"
down_revision = "c4e6a8b0d2f5"
branch_labels = None
depends_on = None

EPS = 0.0005

_tx = sa.table(
    "inventory_transactions",
    sa.column("id", sa.String), sa.column("item_id", sa.String), sa.column("direction", sa.String), sa.column("quantity", sa.Float),
    sa.column("unit_cost", sa.Float), sa.column("reason", sa.String), sa.column("linked_entity_type", sa.String),
    sa.column("linked_entity_id", sa.String), sa.column("lot_id", sa.String), sa.column("correlation_id", sa.String),
    sa.column("stock_exception_id", sa.String), sa.column("created_at", sa.DateTime(timezone=True)),
)
_lot = sa.table(
    "feed_lots",
    sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("feed_product_id", sa.String), sa.column("lot_code", sa.String),
    sa.column("source_type", sa.String), sa.column("received_at", sa.DateTime(timezone=True)), sa.column("received_quantity", sa.Float),
    sa.column("accepted_quantity", sa.Float), sa.column("rejected_quantity", sa.Float), sa.column("quantity_on_hand", sa.Float),
    sa.column("unit", sa.String), sa.column("unit_cost", sa.Float), sa.column("status", sa.String), sa.column("notes", sa.Text),
    sa.column("created_at", sa.DateTime(timezone=True)),
)
_exc = sa.table(
    "feed_stock_exceptions",
    sa.column("id", sa.String), sa.column("farm_id", sa.String), sa.column("feed_product_id", sa.String), sa.column("inventory_item_id", sa.String),
    sa.column("kind", sa.String), sa.column("quantity", sa.Float), sa.column("resolved_quantity", sa.Float), sa.column("unit", sa.String),
    sa.column("status", sa.String), sa.column("reason", sa.Text), sa.column("source_entity_type", sa.String), sa.column("source_entity_id", sa.String),
    sa.column("lot_id", sa.String), sa.column("detail", sa.JSON), sa.column("occurred_at", sa.DateTime(timezone=True)),
    sa.column("created_at", sa.DateTime(timezone=True)),
)


def upgrade() -> None:
    op.create_table(
        "feed_stock_exceptions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("farm_id", sa.String(36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("feed_product_id", sa.String(36), sa.ForeignKey("feed_products.id"), nullable=False),
        sa.Column("inventory_item_id", sa.String(36), sa.ForeignKey("inventory_items.id"), nullable=False),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("resolved_quantity", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(20), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("requested_by", sa.String(36), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("approved_by", sa.String(36), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("approval_request_id", sa.String(36), nullable=True),
        sa.Column("source_entity_type", sa.String(50), nullable=True),
        sa.Column("source_entity_id", sa.String(36), nullable=True),
        sa.Column("lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("detail", sa.JSON(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("resolution", sa.String(40), nullable=True),
        sa.Column("resolution_note", sa.Text(), nullable=True),
        sa.Column("resolution_lot_id", sa.String(36), sa.ForeignKey("feed_lots.id"), nullable=True),
        sa.Column("resolution_reference_id", sa.String(36), nullable=True),
        sa.Column("resolved_by", sa.String(36), sa.ForeignKey("users.id"), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_feed_stock_exceptions_product_status", "feed_stock_exceptions", ["feed_product_id", "status"])
    with op.batch_alter_table("inventory_transactions") as batch:
        batch.add_column(sa.Column("stock_exception_id", sa.String(36), nullable=True))
        batch.add_column(sa.Column("actor_user_id", sa.String(36), nullable=True))
        batch.create_foreign_key("fk_inventory_transactions_stock_exception", "feed_stock_exceptions", ["stock_exception_id"], ["id"])
    backfill(op.get_bind())


def downgrade() -> None:
    with op.batch_alter_table("inventory_transactions") as batch:
        batch.drop_constraint("fk_inventory_transactions_stock_exception", type_="foreignkey")
        batch.drop_column("actor_user_id")
        batch.drop_column("stock_exception_id")
    op.drop_index("ix_feed_stock_exceptions_product_status", table_name="feed_stock_exceptions")
    op.drop_table("feed_stock_exceptions")


# ------------------------------------------------------------------ data
def _signed_sums(conn, item_id: str) -> dict:
    rows = conn.execute(sa.text(
        "SELECT lot_id, COALESCE(SUM(CASE WHEN direction = 'in' THEN quantity ELSE -quantity END), 0) "
        "FROM inventory_transactions WHERE item_id = :item GROUP BY lot_id"
    ), {"item": item_id}).all()
    return {r[0]: float(r[1] or 0) for r in rows}


def _move(conn, *, item_id: str, lot_id: str | None, signed: float, unit_cost, linked_id: str, correlation: str, when, reason: str = "ledger_carry_over") -> None:
    conn.execute(_tx.insert().values(
        id=str(uuid.uuid4()), item_id=item_id, direction="in" if signed > 0 else "out", quantity=round(abs(signed), 6), unit_cost=unit_cost,
        reason=reason, linked_entity_type="inventory_migration", linked_entity_id=linked_id, lot_id=lot_id, correlation_id=correlation,
        stock_exception_id=None, created_at=when,
    ))


def _pair(conn, *, item_id: str, lot_id: str, signed_on_lot: float, unit_cost, linked_id: str, when, reason: str = "ledger_carry_over") -> None:
    """`signed_on_lot` onto the lot, the opposite onto no lot: the stock
    line does not move."""
    correlation = str(uuid.uuid4())
    _move(conn, item_id=item_id, lot_id=lot_id, signed=signed_on_lot, unit_cost=unit_cost, linked_id=linked_id, correlation=correlation, when=when, reason=reason)
    _move(conn, item_id=item_id, lot_id=None, signed=-signed_on_lot, unit_cost=unit_cost, linked_id=linked_id, correlation=correlation, when=when, reason=reason)


def _unique_code(conn, farm_id: str, base: str) -> str:
    code, n = base, 2
    while conn.execute(sa.text("SELECT 1 FROM feed_lots WHERE farm_id = :f AND lot_code = :c"), {"f": farm_id, "c": code}).first():
        code = f"{base}-{n}"
        n += 1
    return code


def backfill(conn) -> dict:
    """Runs per feed product; returns what it did (the test reads it)."""
    now = datetime.now(timezone.utc)
    report = {"lot_pairs": 0, "negative_lots": 0, "stock_line_rows": 0, "carried_lots": 0, "exceptions": 0}
    products = conn.execute(sa.text(
        "SELECT p.id, p.farm_id, p.code, p.unit, p.inventory_item_id, i.current_qty, i.unit_cost "
        "FROM feed_products p JOIN inventory_items i ON i.id = p.inventory_item_id ORDER BY p.id"
    )).all()
    for pid, farm_id, code, unit, item_id, stored_line, item_cost in products:
        lots = conn.execute(sa.text(
            "SELECT id, lot_code, quantity_on_hand, unit_cost, created_at FROM feed_lots WHERE feed_product_id = :p ORDER BY received_at, id"
        ), {"p": pid}).all()
        sums = _signed_sums(conn, item_id)
        negative = []
        for lot_id, lot_code, qoh, lot_cost, _created in lots:
            qoh = float(qoh or 0)
            implicit = round(qoh - sums.get(lot_id, 0.0), 6)
            if abs(implicit) > EPS:
                _pair(conn, item_id=item_id, lot_id=lot_id, signed_on_lot=implicit, unit_cost=lot_cost, linked_id=lot_id, when=now)
                report["lot_pairs"] += 1
            if qoh < -EPS:
                _pair(conn, item_id=item_id, lot_id=lot_id, signed_on_lot=-qoh, unit_cost=lot_cost, linked_id=lot_id, when=now)
                conn.execute(sa.text("UPDATE feed_lots SET quantity_on_hand = 0, status = 'depleted' WHERE id = :l"), {"l": lot_id})
                negative.append({"lot_id": lot_id, "lot_code": lot_code, "quantity": round(qoh, 6)})
                report["negative_lots"] += 1
        sums = _signed_sums(conn, item_id)
        stored_line = float(stored_line or 0)
        drift = round(stored_line - sum(sums.values()), 6)
        if abs(drift) > EPS:
            _move(conn, item_id=item_id, lot_id=None, signed=drift, unit_cost=item_cost, linked_id=item_id, correlation=str(uuid.uuid4()), when=now)
            report["stock_line_rows"] += 1
        untraced = round(_signed_sums(conn, item_id).get(None, 0.0), 6)
        if untraced > EPS:
            lot_id = str(uuid.uuid4())
            conn.execute(_lot.insert().values(
                id=lot_id, farm_id=farm_id, feed_product_id=pid, lot_code=_unique_code(conn, farm_id, f"{code}-{'CARRIED' if lots else 'OPENING'}"),
                source_type="opening_balance",
                received_at=now, received_quantity=untraced, accepted_quantity=untraced, rejected_quantity=0, quantity_on_hand=untraced, unit=unit,
                unit_cost=item_cost, status="active", notes="Stock on record with no lot, carried into a lot of its own (v0.8.4).", created_at=now,
            ))
            _pair(conn, item_id=item_id, lot_id=lot_id, signed_on_lot=untraced, unit_cost=item_cost, linked_id=lot_id, when=now)
            report["carried_lots"] += 1
        elif untraced < -EPS:
            first_lot_at = min((l[4] for l in lots if l[4] is not None), default=None)
            q = ("SELECT t.id, t.created_at, t.direction, t.quantity, t.reason, t.linked_entity_type, t.linked_entity_id "
                 "FROM inventory_transactions t WHERE t.item_id = :item AND t.lot_id IS NULL "
                 "AND (t.linked_entity_type IS NULL OR t.linked_entity_type <> 'inventory_migration')")
            params = {"item": item_id}
            if first_lot_at is not None:
                q += " AND t.created_at >= :since"
                params["since"] = first_lot_at
            rows = conn.execute(sa.text(q + " ORDER BY t.created_at"), params).all()
            moves = []
            for tid, at, direction, qty, reason, ltype, lid in rows[:500]:
                who = None
                if ltype == "feeding_event" and lid:
                    who = conn.execute(sa.text("SELECT recorded_by FROM feeding_events WHERE id = :e"), {"e": lid}).scalar()
                moves.append({"id": tid, "at": at.isoformat() if hasattr(at, "isoformat") else str(at), "direction": direction, "quantity": float(qty),
                              "reason": reason, "linked_entity_type": ltype, "linked_entity_id": lid, "recorded_by": who})
            conn.execute(_exc.insert().values(
                id=str(uuid.uuid4()), farm_id=farm_id, feed_product_id=pid, inventory_item_id=item_id, kind="legacy_untraced",
                quantity=-untraced, resolved_quantity=0, unit=unit, status="open",
                reason=("Issued with no lot before v0.8.4 (an override, a named lot that held too little, or a lot taken below zero); "
                        "the approval was not recorded then. Reconcile it: count the stock, or name the lot it came from."),
                source_entity_type="inventory_item", source_entity_id=item_id, lot_id=negative[0]["lot_id"] if len(negative) == 1 else None,
                detail={"transactions": moves, "negative_lots": negative, "stock_line_difference": drift if abs(drift) > EPS else None,
                        "migrated_at": now.isoformat()},
                occurred_at=now, created_at=now,
            ))
            report["exceptions"] += 1
    return report
