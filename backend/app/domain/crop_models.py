"""The work on a crop cycle (master prompt Package 7; database/CROPS-SCHEMA.md
§5 field_operation, §6 field_operation_input, §8 irrigation_event).

A crop cycle is the existing `crop_plantings` row: one crop in one growing
unit (a field, a greenhouse, a tunnel, an orchard block) from planting to
its last harvest. What is done to it is recorded here; what it used comes
out of the farm's stock through the inventory ledger (an `out` movement
per input, never a balance kept on the side); what it gave goes into stock
at harvest (`harvest_records`, `inventory_transactions`); what it earned
is the sales linked to it. Its margin is read from those records.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, ForeignKey, Index, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


# Work done on a crop (CROPS-SCHEMA §5 examples, lower case).
OPERATION_TYPES = ("plant", "fertilize", "spray", "weed", "prune", "irrigate", "harvest_prep", "other")
# Growing units (fields.unit_type).
UNIT_TYPES = ("open_field", "greenhouse", "tunnel", "orchard")
PURPOSES = ("sale", "feed", "seed", "mixed")


class FieldOperation(Base):
    """One piece of work done on a crop cycle: what, when, by whom, the
    labour it took (hours and its cost) and the inputs it used."""

    __tablename__ = "field_operations"
    __table_args__ = (Index("ix_field_operations_cycle", "crop_planting_id", "completed_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    crop_planting_id: Mapped[str] = mapped_column(String(36), ForeignKey("crop_plantings.id"))
    field_id: Mapped[str] = mapped_column(String(36), ForeignKey("fields.id"))
    operation_type: Mapped[str] = mapped_column(String(30))
    completed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    # completed | reversed (a mistake undone: its inputs return to stock)
    status: Mapped[str] = mapped_column(String(20), default="completed")
    labour_hours: Mapped[float | None] = mapped_column(Float, nullable=True)
    # In USD; null when the labour was not priced (shown as unpriced).
    labour_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    performed_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    inputs: Mapped[list["FieldOperationInput"]] = relationship(back_populates="operation", cascade="all, delete-orphan")


class FieldOperationInput(Base):
    """A seed, fertiliser, plant treatment or other stock item the work used:
    taken out of stock by its own ledger movement, at the item's cost."""

    __tablename__ = "field_operation_inputs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    field_operation_id: Mapped[str] = mapped_column(String(36), ForeignKey("field_operations.id"), index=True)
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    quantity: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(20))
    # Per unit and in total, in USD at the time; null when the item has no cost.
    unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    inventory_transaction_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("inventory_transactions.id"), nullable=True)

    operation: Mapped["FieldOperation"] = relationship(back_populates="inputs")


class IrrigationEvent(Base):
    """Water given to a crop cycle (CROPS-SCHEMA §8): how much, when, from
    which source, and what the pumping cost when it is known."""

    __tablename__ = "irrigation_events"
    __table_args__ = (Index("ix_irrigation_events_cycle", "crop_planting_id", "started_at"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    crop_planting_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("crop_plantings.id"), nullable=True)
    field_id: Mapped[str] = mapped_column(String(36), ForeignKey("fields.id"))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    water_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    unit: Mapped[str | None] = mapped_column(String(10), nullable=True)  # m3 | L
    source_code: Mapped[str | None] = mapped_column(String(60), nullable=True)  # well | network | canal | rain_tank
    # In USD (electricity or fuel for the pump); null when not known.
    energy_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
