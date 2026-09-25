"""Generic animal model: species as data, typed identifiers, capabilities.

Revision ID: 7c2e9a41d5b8
Revises: 3d92c6a5f1b7
Create Date: 2026-09-25

Implements docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md. One `Animal` entity
already existed; what was missing was everything that describes it as
configuration rather than code:

* `species`, `breeds`, `life_stages`, `management_profiles` — the inputs
  to the capability resolver. `species.code` is the natural key, because
  it is the value every existing row and every tablet already uses.
* `capabilities` and `species_capability_rules` — what a given species /
  sex / stage / profile can participate in, and which identifiers it must
  carry.
* `animal_identifiers` — ear tag, RFID, microchip, leg band, passport…
  as rows, replacing the assumption that every animal has one ear tag.

`animals.tag` becomes nullable and every existing value is copied into an
identifier row (ear tag for mammals, leg band for poultry) so nothing is
lost and every screen that shows `#744` keeps working. Animals recorded
as lactating get the `dairy` profile — that is inference from recorded
state, not a guess, and without it their next milk record would be
refused. `flocks` gains the group fields the model needs.

The reference data is inserted here from `app.livestock.catalog`, so a
production database upgraded by this migration is complete on its own.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

from app.livestock.reference import migration_rows

revision: str = "7c2e9a41d5b8"
down_revision: Union[str, None] = "3d92c6a5f1b7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ------------------------------------------------------ reference tables
    species = op.create_table(
        "species",
        sa.Column("code", sa.String(length=30), primary_key=True),
        sa.Column("name_en", sa.String(length=80), nullable=False),
        sa.Column("name_ar", sa.String(length=80), nullable=False),
        sa.Column("reproduction_mode", sa.String(length=20), nullable=False, server_default="unspecified"),
        sa.Column("icon", sa.String(length=30), nullable=False, server_default="barn"),
        sa.Column("default_management", sa.String(length=20), nullable=False, server_default="either"),
        sa.Column("terminology_json", sa.JSON(), nullable=False),
        sa.Column("profiles_json", sa.JSON(), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="100"),
    )
    breeds = op.create_table(
        "breeds",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("species_code", sa.String(length=30), sa.ForeignKey("species.code"), nullable=False),
        sa.Column("name", sa.String(length=100), nullable=False),
        sa.Column("name_ar", sa.String(length=100), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    life_stages = op.create_table(
        "life_stages",
        sa.Column("code", sa.String(length=30), primary_key=True),
        sa.Column("species_code", sa.String(length=30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("label_en", sa.String(length=80), nullable=False),
        sa.Column("label_ar", sa.String(length=80), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="100"),
    )
    management_profiles = op.create_table(
        "management_profiles",
        sa.Column("code", sa.String(length=30), primary_key=True),
        sa.Column("species_code", sa.String(length=30), sa.ForeignKey("species.code"), nullable=True),
        sa.Column("label_en", sa.String(length=80), nullable=False),
        sa.Column("label_ar", sa.String(length=80), nullable=False),
    )
    capabilities = op.create_table(
        "capabilities",
        sa.Column("code", sa.String(length=40), primary_key=True),
        sa.Column("category", sa.String(length=30), nullable=False),
        sa.Column("label_en", sa.String(length=80), nullable=False),
        sa.Column("label_ar", sa.String(length=80), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    rules = op.create_table(
        "species_capability_rules",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("species_code", sa.String(length=30), sa.ForeignKey("species.code"), nullable=False),
        sa.Column("capability_code", sa.String(length=40), sa.ForeignKey("capabilities.code"), nullable=False),
        sa.Column("sex", sa.String(length=5), nullable=True),
        sa.Column("life_stage", sa.String(length=30), sa.ForeignKey("life_stages.code"), nullable=True),
        sa.Column("management_profile", sa.String(length=30), sa.ForeignKey("management_profiles.code"), nullable=True),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("configuration_json", sa.JSON(), nullable=True),
        sa.Column("priority", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_index("ix_species_capability_rules_species", "species_capability_rules", ["species_code"])

    rows = migration_rows()
    op.bulk_insert(species, rows["species"])
    op.bulk_insert(life_stages, rows["life_stages"])
    op.bulk_insert(management_profiles, rows["management_profiles"])
    op.bulk_insert(capabilities, rows["capabilities"])
    op.bulk_insert(breeds, rows["breeds"])
    op.bulk_insert(rules, rows["species_capability_rules"])

    # ------------------------------------------------------------ identifiers
    op.create_table(
        "animal_identifiers",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("animal_id", sa.String(length=36), sa.ForeignKey("animals.id"), nullable=False),
        sa.Column("identifier_type", sa.String(length=30), nullable=False),
        sa.Column("identifier_value", sa.String(length=120), nullable=False),
        sa.Column("issuing_authority", sa.String(length=120), nullable=True),
        sa.Column("valid_from", sa.DateTime(timezone=True), nullable=True),
        sa.Column("valid_to", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_primary", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("status", sa.String(length=20), nullable=False, server_default="active"),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_animal_identifiers_animal", "animal_identifiers", ["animal_id"])
    op.create_index("ix_animal_identifiers_lookup", "animal_identifiers", ["identifier_type", "identifier_value"])

    # --------------------------------------------------------------- animals
    # Batch mode so this also runs on SQLite (dev/tests), which cannot
    # ALTER a column or add a foreign key in place.
    with op.batch_alter_table("animals") as batch:
        batch.alter_column("tag", existing_type=sa.String(length=50), nullable=True)
        batch.add_column(sa.Column("breed_id", sa.String(length=36), nullable=True))
        batch.add_column(sa.Column("birth_date_estimated", sa.Boolean(), nullable=False, server_default=sa.false()))
        batch.add_column(sa.Column("life_stage", sa.String(length=30), nullable=True))
        batch.add_column(sa.Column("management_profile", sa.String(length=30), nullable=True))
        batch.create_foreign_key("fk_animals_species", "species", ["species"], ["code"])
        batch.create_foreign_key("fk_animals_breed", "breeds", ["breed_id"], ["id"])
        batch.create_foreign_key("fk_animals_life_stage", "life_stages", ["life_stage"], ["code"])
        batch.create_foreign_key("fk_animals_management_profile", "management_profiles", ["management_profile"], ["code"])

    with op.batch_alter_table("flocks") as batch:
        batch.add_column(sa.Column("group_type", sa.String(length=20), nullable=False, server_default="flock"))
        batch.add_column(sa.Column("sex_composition", sa.String(length=20), nullable=True))
        batch.add_column(sa.Column("life_stage", sa.String(length=30), nullable=True))
        batch.add_column(sa.Column("management_profile", sa.String(length=30), nullable=True))
        batch.create_foreign_key("fk_flocks_species", "species", ["species"], ["code"])
        batch.create_foreign_key("fk_flocks_life_stage", "life_stages", ["life_stage"], ["code"])
        batch.create_foreign_key("fk_flocks_management_profile", "management_profiles", ["management_profile"], ["code"])

    # ------------------------------------------------------------- backfill
    _backfill(op.get_bind())


def _backfill(bind) -> None:
    import uuid
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc)
    oviparous = {
        r[0] for r in bind.execute(sa.text("SELECT code FROM species WHERE reproduction_mode = 'oviparous'"))
    }
    animals = bind.execute(
        sa.text("SELECT id, species, tag, lactating FROM animals WHERE tag IS NOT NULL AND TRIM(tag) <> ''")
    ).fetchall()
    for animal_id, species, tag, lactating in animals:
        bind.execute(
            sa.text(
                "INSERT INTO animal_identifiers "
                "(id, animal_id, identifier_type, identifier_value, is_primary, status, created_at) "
                "VALUES (:id, :animal_id, :type, :value, :primary, 'active', :now)"
            ),
            {
                "id": str(uuid.uuid4()),
                "animal_id": animal_id,
                "type": "LEG_BAND" if species in oviparous else "EAR_TAG",
                "value": tag.strip(),
                "primary": True,
                "now": now,
            },
        )
    # A lactating animal is a dairy animal: without a profile its next
    # milk record would be refused by the resolver.
    bind.execute(
        sa.text(
            "UPDATE animals SET management_profile = 'dairy' "
            "WHERE management_profile IS NULL AND lactating = :yes"
        ),
        {"yes": True},
    )
    # Laying flocks are female by definition of what they are kept for.
    bind.execute(sa.text("UPDATE flocks SET sex_composition = 'female', management_profile = 'layer' "
                         "WHERE sex_composition IS NULL"))


def downgrade() -> None:
    bind = op.get_bind()
    # Put the primary identifier back into `tag` before the table goes.
    rows = bind.execute(
        sa.text(
            "SELECT animal_id, identifier_value FROM animal_identifiers "
            "WHERE is_primary = :yes AND status = 'active'"
        ),
        {"yes": True},
    ).fetchall()
    for animal_id, value in rows:
        bind.execute(
            sa.text("UPDATE animals SET tag = :tag WHERE id = :id AND (tag IS NULL OR TRIM(tag) = '')"),
            {"tag": value, "id": animal_id},
        )
    bind.execute(sa.text("UPDATE animals SET tag = '' WHERE tag IS NULL"))

    with op.batch_alter_table("flocks") as batch:
        batch.drop_constraint("fk_flocks_management_profile", type_="foreignkey")
        batch.drop_constraint("fk_flocks_life_stage", type_="foreignkey")
        batch.drop_constraint("fk_flocks_species", type_="foreignkey")
        for column in ("management_profile", "life_stage", "sex_composition", "group_type"):
            batch.drop_column(column)

    with op.batch_alter_table("animals") as batch:
        batch.drop_constraint("fk_animals_management_profile", type_="foreignkey")
        batch.drop_constraint("fk_animals_life_stage", type_="foreignkey")
        batch.drop_constraint("fk_animals_breed", type_="foreignkey")
        batch.drop_constraint("fk_animals_species", type_="foreignkey")
        for column in ("management_profile", "life_stage", "birth_date_estimated", "breed_id"):
            batch.drop_column(column)
        batch.alter_column("tag", existing_type=sa.String(length=50), nullable=False)

    op.drop_index("ix_animal_identifiers_lookup", table_name="animal_identifiers")
    op.drop_index("ix_animal_identifiers_animal", table_name="animal_identifiers")
    op.drop_table("animal_identifiers")
    op.drop_index("ix_species_capability_rules_species", table_name="species_capability_rules")
    op.drop_table("species_capability_rules")
    op.drop_table("capabilities")
    op.drop_table("management_profiles")
    op.drop_table("life_stages")
    op.drop_table("breeds")
    op.drop_table("species")
