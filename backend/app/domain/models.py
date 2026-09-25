"""SQLAlchemy ORM models — one class per table in tech spec §9
"Database Schema - MVP Tables". Kept engine-agnostic (plain String ids,
generic JSON) so the same models work against SQLite (local/demo/tests)
and PostgreSQL (pilot/staging/production, see database/schema.sql for the
authoritative PostgreSQL DDL).
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Farm(Base):
    __tablename__ = "farms"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(200))
    country: Mapped[str] = mapped_column(String(100), default="Lebanon")
    region: Mapped[str] = mapped_column(String(100), default="Bekaa Valley")
    timezone: Mapped[str] = mapped_column(String(50), default="Asia/Beirut")
    default_currency: Mapped[str] = mapped_column(String(10), default="USD")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    phone: Mapped[str | None] = mapped_column(String(50), nullable=True)
    email: Mapped[str | None] = mapped_column(String(200), nullable=True, unique=True)
    password_hash: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(30))
    language: Mapped[str] = mapped_column(String(5), default="en")
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class Location(Base):
    __tablename__ = "locations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    parent_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    name: Mapped[str] = mapped_column(String(200))
    type: Mapped[str | None] = mapped_column(String(50), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)


class Animal(Base):
    __tablename__ = "animals"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    tag: Mapped[str] = mapped_column(String(50))
    name: Mapped[str] = mapped_column(String(200))
    species: Mapped[str] = mapped_column(String(30))
    breed: Mapped[str | None] = mapped_column(String(100), nullable=True)
    sex: Mapped[str | None] = mapped_column(String(5), nullable=True)
    birth_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    status: Mapped[str] = mapped_column(String(30), default="healthy")
    location_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    location_label: Mapped[str | None] = mapped_column(String(200), nullable=True)
    health_score: Mapped[int] = mapped_column(Integer, default=100)
    pregnant: Mapped[bool] = mapped_column(Boolean, default=False)
    pregnancy_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    lactating: Mapped[bool] = mapped_column(Boolean, default=False)
    lactation_cycle: Mapped[int | None] = mapped_column(Integer, nullable=True)
    withdrawal_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    withdrawal_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    group_name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    photo_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, onupdate=_now)


class Flock(Base):
    __tablename__ = "flocks"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    species: Mapped[str] = mapped_column(String(30))
    count: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(30), default="healthy")
    location_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    location_label: Mapped[str | None] = mapped_column(String(200), nullable=True)


class Field(Base):
    __tablename__ = "fields"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    crop_type: Mapped[str | None] = mapped_column(String(100), nullable=True)
    area_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    area_unit: Mapped[str | None] = mapped_column(String(20), nullable=True)
    stage: Mapped[str | None] = mapped_column(String(30), nullable=True)
    expected_harvest_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    est_yield_kg: Mapped[float | None] = mapped_column(Float, nullable=True)


class InventoryItem(Base):
    __tablename__ = "inventory_items"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    category: Mapped[str | None] = mapped_column(String(50), nullable=True)
    unit: Mapped[str] = mapped_column(String(20))
    current_qty: Mapped[float] = mapped_column(Float, default=0)
    reorder_level: Mapped[float] = mapped_column(Float, default=0)
    supplier_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("suppliers.id"), nullable=True)
    supplier_label: Mapped[str | None] = mapped_column(String(200), nullable=True)
    unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    last_purchase: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class InventoryTransaction(Base):
    __tablename__ = "inventory_transactions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    direction: Mapped[str] = mapped_column(String(10))  # 'in' | 'out'
    quantity: Mapped[float] = mapped_column(Float)
    unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    reason: Mapped[str | None] = mapped_column(String(100), nullable=True)
    linked_entity_type: Mapped[str | None] = mapped_column(String(50), nullable=True)
    linked_entity_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Observation(Base):
    __tablename__ = "observations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    entity_type: Mapped[str] = mapped_column(String(30))
    entity_id: Mapped[str] = mapped_column(String(36))
    observation_type: Mapped[str] = mapped_column(String(50))
    value_numeric: Mapped[float | None] = mapped_column(Float, nullable=True)
    value_text: Mapped[str | None] = mapped_column(String(500), nullable=True)
    unit: Mapped[str | None] = mapped_column(String(20), nullable=True)
    severity: Mapped[str | None] = mapped_column(String(20), nullable=True)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    observer_id: Mapped[str] = mapped_column(String(36))
    quality: Mapped[str] = mapped_column(String(30), default="human_observed")
    confidence: Mapped[float] = mapped_column(Float, default=0.65)
    verification_status: Mapped[str] = mapped_column(String(20), default="unverified")
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)


class Event(Base):
    __tablename__ = "events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    entity_type: Mapped[str] = mapped_column(String(30))
    entity_id: Mapped[str] = mapped_column(String(36))
    event_type: Mapped[str] = mapped_column(String(50))
    payload_json: Mapped[dict] = mapped_column(JSON, default=dict)
    device_id: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_by: Mapped[str] = mapped_column(String(36))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    server_created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Task(Base):
    __tablename__ = "tasks"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    title: Mapped[str] = mapped_column(String(300))
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    assigned_to: Mapped[str | None] = mapped_column(String(36), nullable=True)
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    priority: Mapped[str] = mapped_column(String(10), default="medium")
    status: Mapped[str] = mapped_column(String(20), default="open")
    source_type: Mapped[str | None] = mapped_column(String(30), nullable=True)
    source_id: Mapped[str | None] = mapped_column(String(36), nullable=True)


class Recommendation(Base):
    __tablename__ = "recommendations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    category: Mapped[str] = mapped_column(String(30))
    priority: Mapped[str] = mapped_column(String(10))
    title: Mapped[str] = mapped_column(String(300))
    entity_type: Mapped[str | None] = mapped_column(String(30), nullable=True)
    entity_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    entity_label: Mapped[str | None] = mapped_column(String(200), nullable=True)
    confidence: Mapped[float] = mapped_column(Float)
    rationale: Mapped[str] = mapped_column(Text)
    suggested_action: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(20), default="generated")
    rule_id: Mapped[str | None] = mapped_column(String(60), nullable=True)
    generated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    decided_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    evidence: Mapped[list["RecommendationEvidence"]] = relationship(
        back_populates="recommendation", cascade="all, delete-orphan"
    )


class RecommendationEvidence(Base):
    __tablename__ = "recommendation_evidence"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    recommendation_id: Mapped[str] = mapped_column(String(36), ForeignKey("recommendations.id"))
    evidence_type: Mapped[str] = mapped_column(String(50), default="metric")
    label: Mapped[str] = mapped_column(String(100))
    value: Mapped[str] = mapped_column(String(200))
    weight: Mapped[float] = mapped_column(Float, default=1.0)
    note: Mapped[str | None] = mapped_column(String(300), nullable=True)

    recommendation: Mapped[Recommendation] = relationship(back_populates="evidence")


class MilkRecord(Base):
    __tablename__ = "milk_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    animal_id: Mapped[str] = mapped_column(String(36), ForeignKey("animals.id"))
    session: Mapped[str] = mapped_column(String(10))
    liters: Mapped[float] = mapped_column(Float)
    quality_status: Mapped[str] = mapped_column(String(20), default="normal")
    destination: Mapped[str] = mapped_column(String(20))
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    recorded_by: Mapped[str | None] = mapped_column(String(36), nullable=True)


class EggRecord(Base):
    __tablename__ = "egg_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    flock_id: Mapped[str] = mapped_column(String(36), ForeignKey("flocks.id"))
    total_eggs: Mapped[int] = mapped_column(Integer)
    sellable_eggs: Mapped[int] = mapped_column(Integer, default=0)
    broken_eggs: Mapped[int] = mapped_column(Integer, default=0)
    consumed: Mapped[int] = mapped_column(Integer, default=0)
    hatched: Mapped[int] = mapped_column(Integer, default=0)
    wasted: Mapped[int] = mapped_column(Integer, default=0)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class HarvestRecord(Base):
    __tablename__ = "harvest_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    field_id: Mapped[str] = mapped_column(String(36), ForeignKey("fields.id"))
    product_name: Mapped[str] = mapped_column(String(100))
    quantity: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(20), default="kg")
    waste_qty: Mapped[float] = mapped_column(Float, default=0)
    destination: Mapped[str | None] = mapped_column(String(50), nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Treatment(Base):
    __tablename__ = "treatments"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    entity_type: Mapped[str] = mapped_column(String(30))
    entity_id: Mapped[str] = mapped_column(String(36))
    diagnosis: Mapped[str | None] = mapped_column(Text, nullable=True)
    medication: Mapped[str] = mapped_column(String(200))
    dose: Mapped[str] = mapped_column(String(100))
    route: Mapped[str] = mapped_column(String(50))
    start_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    end_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    withdrawal_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    vet_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    responsible_user_id: Mapped[str] = mapped_column(String(36))
    status: Mapped[str] = mapped_column(String(20), default="active")
    cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)


class Customer(Base):
    __tablename__ = "customers"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    phone: Mapped[str | None] = mapped_column(String(50), nullable=True)


class Supplier(Base):
    __tablename__ = "suppliers"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    name: Mapped[str] = mapped_column(String(200))
    phone: Mapped[str | None] = mapped_column(String(50), nullable=True)


class Sale(Base):
    __tablename__ = "sales"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    customer_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("customers.id"), nullable=True)
    product_type: Mapped[str] = mapped_column(String(30))
    product_label: Mapped[str | None] = mapped_column(String(100), nullable=True)
    quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    unit: Mapped[str | None] = mapped_column(String(20), nullable=True)
    amount: Mapped[float] = mapped_column(Float)
    currency: Mapped[str] = mapped_column(String(10), default="USD")
    payment_status: Mapped[str] = mapped_column(String(20))
    sold_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Expense(Base):
    __tablename__ = "expenses"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    supplier_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("suppliers.id"), nullable=True)
    category: Mapped[str] = mapped_column(String(30))
    amount: Mapped[float] = mapped_column(Float)
    currency: Mapped[str] = mapped_column(String(10), default="USD")
    linked_entity_type: Mapped[str | None] = mapped_column(String(30), nullable=True)
    linked_entity_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    incurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class SyncQueueItem(Base):
    __tablename__ = "sync_queue"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    local_event_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    operation: Mapped[str] = mapped_column(String(20))
    entity_type: Mapped[str] = mapped_column(String(30))
    entity_id: Mapped[str] = mapped_column(String(36))
    payload_json: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[str] = mapped_column(String(20), default="pending")
    retry_count: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(String(500), nullable=True)
    idempotency_key: Mapped[str | None] = mapped_column(String(100), nullable=True, unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class AuditLog(Base):
    __tablename__ = "audit_log"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    user_id: Mapped[str] = mapped_column(String(36))
    action: Mapped[str] = mapped_column(String(100))
    entity_type: Mapped[str] = mapped_column(String(30))
    entity_id: Mapped[str] = mapped_column(String(36))
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    metadata_json: Mapped[dict] = mapped_column(JSON, default=dict)
