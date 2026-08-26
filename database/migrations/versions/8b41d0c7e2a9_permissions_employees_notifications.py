"""Role-based operations upgrade: granular module permissions, employee
records, notifications, audit detail, and the agriculture crop model.

Revision ID: 8b41d0c7e2a9
Revises: c57f1a0ec3cb
Create Date: 2026-08-26

Adds the flexible User <-> Module <-> Permission relationship
(`user_module_permissions`) that replaces one-role-per-employee, the
employee fields on `users`, derived `notifications`, the crop/planting
tables behind the agriculture module, and the extra columns the full
Add-Animal / Add-Field records need.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "8b41d0c7e2a9"
down_revision: Union[str, None] = "c57f1a0ec3cb"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ----------------------------------------------------------- users
    for column in (
        sa.Column("job_title", sa.String(length=120), nullable=True),
        sa.Column("employment_status", sa.String(length=30), nullable=False, server_default="active"),
        sa.Column("start_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("photo_path", sa.String(length=500), nullable=True),
        sa.Column("working_days", sa.JSON(), nullable=True),
        sa.Column("working_hours", sa.String(length=100), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
    ):
        op.add_column("users", column)

    # ------------------------------------------- user_module_permissions
    op.create_table(
        "user_module_permissions",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("farm_id", sa.String(length=36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("user_id", sa.String(length=36), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("module_code", sa.String(length=40), nullable=False),
        sa.Column("can_view", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("can_create", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("can_edit", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("can_delete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("can_approve", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("can_export", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("can_assign", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("can_configure", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("granted_by", sa.String(length=36), nullable=True),
        sa.Column("granted_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "module_code", name="uq_user_module"),
    )
    op.create_index("ix_user_module_permissions_user", "user_module_permissions", ["user_id"])

    # ---------------------------------------------------- notifications
    op.create_table(
        "notifications",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("farm_id", sa.String(length=36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=True),
        sa.Column("module_code", sa.String(length=40), nullable=False),
        sa.Column("notification_type", sa.String(length=40), nullable=False),
        sa.Column("title", sa.String(length=300), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("priority", sa.String(length=20), nullable=False, server_default="medium"),
        sa.Column("entity_type", sa.String(length=40), nullable=True),
        sa.Column("entity_id", sa.String(length=36), nullable=True),
        sa.Column("source_type", sa.String(length=40), nullable=True),
        sa.Column("source_id", sa.String(length=36), nullable=True),
        sa.Column("read_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_notifications_farm", "notifications", ["farm_id"])
    op.create_index("ix_notifications_source", "notifications", ["farm_id", "source_type", "source_id"])

    # ------------------------------------------------------------ crops
    op.create_table(
        "crops",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("farm_id", sa.String(length=36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("category", sa.String(length=60), nullable=True),
        sa.Column("default_cycle_days", sa.Integer(), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("farm_id", "name", name="uq_crop_farm_name"),
    )

    op.create_table(
        "crop_plantings",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("farm_id", sa.String(length=36), sa.ForeignKey("farms.id"), nullable=False),
        sa.Column("field_id", sa.String(length=36), sa.ForeignKey("fields.id"), nullable=False),
        sa.Column("crop_id", sa.String(length=36), sa.ForeignKey("crops.id"), nullable=False),
        sa.Column("variety", sa.String(length=120), nullable=True),
        sa.Column("planted_area", sa.Float(), nullable=True),
        sa.Column("area_unit", sa.String(length=20), nullable=True),
        sa.Column("planted_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expected_harvest_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expected_yield_kg", sa.Float(), nullable=True),
        sa.Column("stage", sa.String(length=30), nullable=False, server_default="planted"),
        sa.Column("status", sa.String(length=30), nullable=False, server_default="active"),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_crop_plantings_field", "crop_plantings", ["field_id"])

    # ----------------------------------------------------------- fields
    for column in (
        sa.Column("field_code", sa.String(length=60), nullable=True),
        sa.Column("location_label", sa.String(length=200), nullable=True),
        sa.Column("soil_type", sa.String(length=60), nullable=True),
        sa.Column("irrigation_method", sa.String(length=60), nullable=True),
        sa.Column("status", sa.String(length=30), nullable=False, server_default="active"),
        sa.Column("notes", sa.Text(), nullable=True),
    ):
        op.add_column("fields", column)

    # ---------------------------------------------------------- animals
    for column in (
        sa.Column("acquisition_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acquisition_source", sa.String(length=200), nullable=True),
        sa.Column("sire_tag", sa.String(length=50), nullable=True),
        sa.Column("dam_tag", sa.String(length=50), nullable=True),
        sa.Column("color_markings", sa.String(length=200), nullable=True),
        sa.Column("purchase_cost", sa.Float(), nullable=True),
        sa.Column("current_value", sa.Float(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
    ):
        op.add_column("animals", column)

    # -------------------------------------------------------- audit_log
    for column in (
        sa.Column("module_code", sa.String(length=40), nullable=True),
        sa.Column("summary", sa.String(length=500), nullable=True),
        sa.Column("changes_json", sa.JSON(), nullable=True),
        sa.Column("device", sa.String(length=120), nullable=True),
    ):
        op.add_column("audit_log", column)


def downgrade() -> None:
    for column in ("device", "changes_json", "summary", "module_code"):
        op.drop_column("audit_log", column)
    for column in (
        "notes", "current_value", "purchase_cost", "color_markings",
        "dam_tag", "sire_tag", "acquisition_source", "acquisition_date",
    ):
        op.drop_column("animals", column)
    for column in ("notes", "status", "irrigation_method", "soil_type", "location_label", "field_code"):
        op.drop_column("fields", column)

    op.drop_index("ix_crop_plantings_field", table_name="crop_plantings")
    op.drop_table("crop_plantings")
    op.drop_table("crops")

    op.drop_index("ix_notifications_source", table_name="notifications")
    op.drop_index("ix_notifications_farm", table_name="notifications")
    op.drop_table("notifications")

    op.drop_index("ix_user_module_permissions_user", table_name="user_module_permissions")
    op.drop_table("user_module_permissions")

    for column in (
        "notes", "working_hours", "working_days", "photo_path",
        "start_date", "employment_status", "job_title",
    ):
        op.drop_column("users", column)
