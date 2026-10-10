"""Medicine & farm pharmacy management (database/MEDICINE-PHARMACY-SCHEMA.md).

A farm pharmacy is not a treatment history: the farm must know what
medicine it owns, where, in which lot with which expiry, what is eligible
to use, what must always be kept and when to reorder — even when no
animal is sick.

Inventory stays the physical stock ledger (`inventory_items` and
`inventory_transactions`). This module adds pharmaceutical semantics to
an item (`medicine_products`), a canonical lot for non-feed stock
(`inventory_lots`, which `medicine_lot_details` extends), the farm's own
essential-stock policy, deduplicated stock alerts and the administration
record that binds a dose to the exact lot it came from. Nothing here is
a second stock balance: every lot quantity moves only with a posted
transaction, and eligibility is computed from lot facts on read.

Feed keeps its own lot table (`feed_lots`) for now; `inventory_lots` is
the generic one the doc calls `inventory_lot`, and folding feed lots into
it is a later migration, not a second design.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, Boolean, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


LOT_STATUSES = ("active", "quarantined", "blocked", "recalled", "expired", "depleted")
STORAGE_STATUSES = ("COMPLIANT", "EXCEPTION")
ALERT_TYPES = (
    "BELOW_MINIMUM_STOCK", "CRITICAL_STOCK", "OUT_OF_STOCK", "LOW_DAYS_COVER",
    "EXPIRING_SOON", "EXPIRED_STOCK", "RECALL_AFFECTED", "STORAGE_EXCEPTION",
)
STOCK_ALERT_TYPES = ("BELOW_MINIMUM_STOCK", "CRITICAL_STOCK", "OUT_OF_STOCK")
DOSAGE_FORMS = ("injectable", "oral", "intravenous_fluid", "topical", "intramammary", "pour_on", "vaccine", "powder", "bolus", "other")
ROUTES = ("IM", "IV", "SC", "PO", "topical", "intramammary", "pour_on", "intranasal", "ocular", "other")


# ------------------------------------------------------------ reference
class MedicineCategory(Base):
    """Organisation, search and essential-stock policy — never a
    diagnosis. Category membership never authorises treatment (§4)."""

    __tablename__ = "medicine_categories"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    code: Mapped[str] = mapped_column(String(80), unique=True)
    name: Mapped[str] = mapped_column(String(150))
    name_ar: Mapped[str | None] = mapped_column(String(150), nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class MedicineActiveIngredient(Base):
    __tablename__ = "medicine_active_ingredients"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    code: Mapped[str] = mapped_column(String(80), unique=True)
    name: Mapped[str] = mapped_column(String(180))
    active: Mapped[bool] = mapped_column(Boolean, default=True)


# -------------------------------------------------------------- product
class MedicineProduct(Base):
    """Pharmaceutical semantics over one canonical inventory item (§2).
    The item keeps the name, unit and balance; this row says what the
    medicine is, how it is stored, whether it needs a prescription, and
    the withdrawal rule an administration applies."""

    __tablename__ = "medicine_products"

    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"), primary_key=True)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    generic_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    brand_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    dosage_form: Mapped[str] = mapped_column(String(60), default="injectable")
    strength_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    # No UOM table in this codebase: a unit is a string the conversion
    # catalogue resolves (feed architecture), e.g. "mg/ml", "IU/ml".
    strength_uom: Mapped[str | None] = mapped_column(String(30), nullable=True)
    strength_basis: Mapped[str | None] = mapped_column(String(80), nullable=True)
    administration_routes: Mapped[list] = mapped_column(JSON, default=list)
    prescription_required: Mapped[bool] = mapped_column(Boolean, default=False)
    antimicrobial: Mapped[bool] = mapped_column(Boolean, default=False)
    controlled_medicine: Mapped[bool] = mapped_column(Boolean, default=False)
    cold_chain_required: Mapped[bool] = mapped_column(Boolean, default=False)
    storage_min_c: Mapped[float | None] = mapped_column(Float, nullable=True)
    storage_max_c: Mapped[float | None] = mapped_column(Float, nullable=True)
    opened_shelf_life_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    default_pack_size: Mapped[float | None] = mapped_column(Float, nullable=True)
    pack_uom: Mapped[str | None] = mapped_column(String(30), nullable=True)
    manufacturer_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    authorization_reference: Mapped[str | None] = mapped_column(String(150), nullable=True)
    # Species the product is authorised for; empty means any. Checked
    # server-side on administration, like a feed usage policy.
    species_codes: Mapped[list] = mapped_column(JSON, default=list)
    # Authorised withdrawal rule, e.g. {"milk_days": 3, "meat_days": 14}.
    # Applied by an administration; never invented at the point of care.
    withdrawal_rules_json: Mapped[dict] = mapped_column(JSON, default=dict)
    # The lot/expiry requirement can only be waived by an explicit,
    # recorded exception (§6).
    lot_tracking_exception: Mapped[str | None] = mapped_column(Text, nullable=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    ingredients: Mapped[list["MedicineProductIngredient"]] = relationship(back_populates="product", cascade="all, delete-orphan")
    categories: Mapped[list["MedicineProductCategory"]] = relationship(back_populates="product", cascade="all, delete-orphan")
    lots: Mapped[list["InventoryLot"]] = relationship(
        primaryjoin="MedicineProduct.inventory_item_id == foreign(InventoryLot.inventory_item_id)", viewonly=True, order_by="InventoryLot.received_at",
    )


class MedicineProductIngredient(Base):
    __tablename__ = "medicine_product_ingredients"

    medicine_product_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_products.inventory_item_id"), primary_key=True)
    active_ingredient_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_active_ingredients.id"), primary_key=True)
    concentration_value: Mapped[float | None] = mapped_column(Float, nullable=True)
    concentration_uom: Mapped[str | None] = mapped_column(String(30), nullable=True)
    concentration_basis: Mapped[str | None] = mapped_column(String(80), nullable=True)

    product: Mapped["MedicineProduct"] = relationship(back_populates="ingredients")
    ingredient: Mapped["MedicineActiveIngredient"] = relationship()


class MedicineProductCategory(Base):
    __tablename__ = "medicine_product_categories"

    medicine_product_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_products.inventory_item_id"), primary_key=True)
    category_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_categories.id"), primary_key=True)

    product: Mapped["MedicineProduct"] = relationship(back_populates="categories")
    category: Mapped["MedicineCategory"] = relationship()


# ----------------------------------------------------------------- lots
class InventoryLot(Base):
    """The canonical lot of a non-feed inventory item (the doc's
    `inventory_lot`): what arrived, what was accepted, what is on hand,
    where it is and until when it is good. On-hand moves only with a
    posted inventory transaction."""

    __tablename__ = "inventory_lots"
    __table_args__ = (UniqueConstraint("inventory_item_id", "lot_code", name="uq_inventory_lot_item_code"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_items.id"))
    lot_code: Mapped[str] = mapped_column(String(120))
    # purchased | opening_balance | donation | return
    source_type: Mapped[str] = mapped_column(String(30), default="purchased")
    supplier_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("suppliers.id"), nullable=True)
    supplier_label: Mapped[str | None] = mapped_column(String(200), nullable=True)
    location_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    expiry_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    received_quantity: Mapped[float] = mapped_column(Float, default=0)
    accepted_quantity: Mapped[float] = mapped_column(Float, default=0)
    rejected_quantity: Mapped[float] = mapped_column(Float, default=0)
    quantity_on_hand: Mapped[float] = mapped_column(Float, default=0)
    unit: Mapped[str] = mapped_column(String(20), default="items")
    unit_cost: Mapped[float | None] = mapped_column(Float, nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="active")
    reference: Mapped[str | None] = mapped_column(String(150), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    medicine: Mapped["MedicineLotDetail | None"] = relationship(back_populates="lot", uselist=False, cascade="all, delete-orphan")


class MedicineLotDetail(Base):
    """Pharmacy metadata over a canonical lot (§6): opened/use-by after
    opening, storage compliance, quarantine and recall provenance."""

    __tablename__ = "medicine_lot_details"

    inventory_lot_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_lots.id"), primary_key=True)
    opened_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    use_by_after_opening: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    storage_status: Mapped[str] = mapped_column(String(30), default="COMPLIANT")
    cold_chain_exception: Mapped[bool] = mapped_column(Boolean, default=False)
    storage_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    quarantine_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    recalled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    recall_reference: Mapped[str | None] = mapped_column(String(150), nullable=True)

    lot: Mapped["InventoryLot"] = relationship(back_populates="medicine")


# --------------------------------------------------------------- policy
class PharmacyStockPolicy(Base):
    """The farm's own decision of what is essential and how much to keep
    (§5). Thresholds are configuration, never medical advice."""

    __tablename__ = "pharmacy_stock_policies"
    __table_args__ = (UniqueConstraint("farm_id", "inventory_item_id", "location_id", name="uq_pharmacy_policy_item_location"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_products.inventory_item_id"))
    location_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    essential: Mapped[bool] = mapped_column(Boolean, default=False)
    minimum_stock_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_stock_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    critical_stock_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    minimum_days_cover: Mapped[float | None] = mapped_column(Float, nullable=True)
    lead_time_days: Mapped[float | None] = mapped_column(Float, nullable=True)
    preferred_supplier_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("suppliers.id"), nullable=True)
    alert_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    expiry_warning_days: Mapped[int] = mapped_column(Integer, default=60)
    # If true, a LOW/CRITICAL/OUT alert opens one draft requisition task
    # (never a purchase order — §9).
    auto_draft_requisition: Mapped[bool] = mapped_column(Boolean, default=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    version: Mapped[int] = mapped_column(Integer, default=1)
    updated_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


# --------------------------------------------------------------- alerts
class PharmacyStockAlert(Base):
    """A deduplicated logistics finding (§8): one open row per condition,
    acknowledged by a person, resolved when the stock condition clears.
    A stock alert is never treatment advice."""

    __tablename__ = "pharmacy_stock_alerts"
    __table_args__ = (UniqueConstraint("farm_id", "deduplication_key", "detected_at", name="uq_pharmacy_alert_dedup"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_products.inventory_item_id"))
    location_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("locations.id"), nullable=True)
    alert_type: Mapped[str] = mapped_column(String(50))
    # critical | high | medium | low
    severity: Mapped[str] = mapped_column(String(20), default="medium")
    detected_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    eligible_available_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    minimum_stock_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_stock_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    earliest_expiry_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expiring_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    recommended_reorder_base: Mapped[float | None] = mapped_column(Float, nullable=True)
    explanation: Mapped[str] = mapped_column(Text, default="")
    # open | acknowledged | resolved
    status: Mapped[str] = mapped_column(String(30), default="open")
    acknowledged_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    resolution_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    deduplication_key: Mapped[str] = mapped_column(String(255))
    requisition_task_id: Mapped[str | None] = mapped_column(String(36), nullable=True)


# ------------------------------------------------------- administration
class MedicationAdministration(Base):
    """One dose actually given (§11): subject, product, the exact lot it
    came from, dose/route/time, the consumption it posted and the
    withdrawal it applied from the product's authorised rule. Reversed by
    a correction, never edited."""

    __tablename__ = "medication_administrations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_uuid)
    farm_id: Mapped[str] = mapped_column(String(36), ForeignKey("farms.id"))
    subject_type: Mapped[str] = mapped_column(String(10))  # animal | group
    subject_id: Mapped[str] = mapped_column(String(36))
    treatment_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("treatments.id"), nullable=True)
    # Set when an approved emergency protocol step prepared this dose.
    protocol_run_step_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    inventory_item_id: Mapped[str] = mapped_column(String(36), ForeignKey("medicine_products.inventory_item_id"))
    inventory_lot_id: Mapped[str] = mapped_column(String(36), ForeignKey("inventory_lots.id"))
    dose_quantity: Mapped[float] = mapped_column(Float)
    dose_unit: Mapped[str] = mapped_column(String(20))
    route_code: Mapped[str] = mapped_column(String(40))
    head_count: Mapped[int] = mapped_column(Integer, default=1)
    quantity_consumed: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(20))
    administered_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    administered_by: Mapped[str] = mapped_column(String(36))
    inventory_transaction_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    withdrawal_milk_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    withdrawal_meat_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    # recorded | reversed
    status: Mapped[str] = mapped_column(String(20), default="recorded")
    reversed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reversal_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
